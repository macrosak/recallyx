import CoreData
import Foundation
#if os(macOS)
import Security
#endif

/// Wraps an `NSPersistentCloudKitContainer` for the history store. CloudKit
/// mirroring is **opt-in AND gated on the build's entitlement**: it is enabled
/// only when `cloudSyncEnabled` is true (the `iCloudSyncEnabled` setting, off by
/// default) **and** this process actually carries the iCloud entitlement
/// (`processHasCloudKitEntitlement`). When off we never set
/// `cloudKitContainerOptions`, so the container behaves as a plain local SQLite
/// store (no entitlement / Apple account needed). When on, the store mirrors to
/// the CloudKit container derived from the public bundle id.
///
/// **Why the entitlement gate matters:** attaching `cloudKitContainerOptions`
/// and loading the store in a process WITHOUT the iCloud entitlement does not
/// "stay inert" — it hard-crashes (`EXC_BREAKPOINT` in
/// `NSCloudKitMirroringDelegate` → CloudKit setup). The Settings toggle ships in
/// EVERY build, including the ad-hoc `bundle.sh`/DMG build that carries no
/// entitlement, so a user who flips it there would otherwise crash-loop at every
/// launch. Gating on `processHasCloudKitEntitlement` makes the toggle safe:
/// on-but-inactive (with a content-free warning) instead of a crash.
///
/// The model is built programmatically (`ClipModel.makeModel()`), so no
/// `.xcdatamodeld` and no Xcode are required — the package stays CLT-buildable.
public final class PersistenceController {
    /// CloudKit container id — derived from the PUBLIC bundle id, so it carries
    /// no team identifier and is safe to hardcode/commit (mirrors the value in
    /// the committed entitlements file + `project.yml`).
    public static let cloudKitContainerIdentifier = "iCloud.io.github.macrosak.recallyx"

    /// Whether THIS running process carries the CloudKit entitlement
    /// (`com.apple.developer.icloud-services`). Only the team-signed Xcode build
    /// (`install-dev.sh`) embeds it; the ad-hoc `bundle.sh`/DMG build and the
    /// unentitled test process do not. Computed once via the Security framework
    /// (already linked). On non-macOS returns true: iOS device / TestFlight
    /// builds are always provisioned with the entitlement (the unsigned-simulator
    /// caveat stays documented — it is the only entitled-less iOS case).
    public static let processHasCloudKitEntitlement: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-services" as CFString, nil
        )
        return value != nil
        #else
        return true
        #endif
    }()

    /// Pure helper (unit-testable without loading a store): the CloudKit options
    /// to attach to the store description, or nil when sync is off **or** the
    /// process lacks the iCloud entitlement. `hasEntitlement` is injectable so
    /// tests don't depend on the test-process's actual entitlements; production
    /// callers get the real `processHasCloudKitEntitlement`.
    public static func cloudKitOptions(
        enabled: Bool,
        hasEntitlement: Bool = PersistenceController.processHasCloudKitEntitlement
    ) -> NSPersistentCloudKitContainerOptions? {
        guard enabled else { return nil }
        guard hasEntitlement else {
            // Content-free: never logs clip text or any secret.
            Log.info("iCloud sync enabled but this build lacks the iCloud entitlement — sync inactive")
            return nil
        }
        return NSPersistentCloudKitContainerOptions(containerIdentifier: cloudKitContainerIdentifier)
    }

    /// Builds the store description **without loading a store** — so a test can
    /// assert the mirroring gate (`cloudKitContainerOptions` set iff enabled AND
    /// entitled) without ever spinning up the real CloudKit mirroring delegate
    /// (loading a mirrored store in an unentitled process crashes in CloudKit).
    public static func makeStoreDescription(
        storeURL: URL? = nil, inMemory: Bool = false, cloudSyncEnabled: Bool = false,
        hasEntitlement: Bool = PersistenceController.processHasCloudKitEntitlement,
        readOnly: Bool = false
    ) -> NSPersistentStoreDescription {
        let url: URL
        if inMemory {
            url = URL(fileURLWithPath: "/dev/null")
        } else {
            url = storeURL ?? URL(fileURLWithPath: "/dev/null")
        }
        let description = NSPersistentStoreDescription(url: url)
        // Opt-in CloudKit mirroring, gated on the process entitlement. nil (the
        // default, and the result whenever the entitlement is absent) keeps the
        // store purely local — no entitlement or iCloud account needed.
        description.cloudKitContainerOptions = cloudKitOptions(
            enabled: cloudSyncEnabled, hasEntitlement: hasEntitlement
        )
        // WAL is the SQLite default; spelled out so a read-only sibling reader
        // (the `recallyx` CLI, a separate process) can read alongside the app's
        // writes.
        description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)

        if readOnly {
            // Read-only sibling reader (the CLI): open the live store WITHOUT
            // history tracking / remote-change / CloudKit. `isReadOnly` makes the
            // coordinator reject every write, so the CLI can never mutate or
            // corrupt the file the app owns. History tracking is itself a WRITE (it
            // stamps transaction rows) and is incompatible with a read-only store,
            // so it is deliberately skipped here — the reader just fetches a
            // snapshot and exits; it needs no change notifications.
            description.isReadOnly = true
            description.cloudKitContainerOptions = nil
            return description
        }

        // Persistent history tracking + remote-change notifications. History
        // tracking is REQUIRED for `.NSPersistentStoreRemoteChange` to fire, which
        // is how the running app learns that a CloudKit import (or any other
        // coordinator writing this file) changed the store, so `HistoryStore` can
        // re-read and merge it into the in-memory `items`. Set on EVERY store
        // (local and mirrored): enabling history tracking on an existing store is
        // safe and one-way — it starts recording transactions; it never rewrites
        // past data — and remote-change notifications on a purely local store with
        // no sibling writer are simply never posted, so this is inert until sync
        // (or a second coordinator) is actually in play.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        return description
    }

    public let container: NSPersistentCloudKitContainer

    /// `viewContext` runs on the main queue; the store reads through it.
    public var viewContext: NSManagedObjectContext { container.viewContext }

    /// Whether CloudKit mirroring is actually active on this container — i.e. the
    /// store description carries `cloudKitContainerOptions` (sync opt-in AND the
    /// process entitled). Callers no-op their refresh UI when this is false.
    var isMirroringActive: Bool {
        container.persistentStoreDescriptions.contains { $0.cloudKitContainerOptions != nil }
    }

    /// Force `NSPersistentCloudKitContainer` to re-run its setup + import cycle by
    /// removing and re-adding the persistent store. NSPCC has **no public
    /// "fetch changes now" API**; reloading the store is the documented public-API
    /// way to trigger a fresh import from the CloudKit server.
    ///
    /// **Safety:** resets `viewContext` first so no managed object is "in use"
    /// during the swap (loading a store while its objects are live is the
    /// documented crash), then removes and re-adds the **same** store file.
    /// Re-adding the same file preserves the mirroring metadata stored inside it,
    /// so CloudKit **resumes** and fetches only new changes — it does NOT
    /// re-download everything (a full reset only happens if the store file is
    /// deleted). Runs on the caller's thread; callers invoke it on the main queue
    /// (the `viewContext`'s queue) and flush pending writes first. The
    /// `.NSPersistentStoreRemoteChange` observer is registered on the
    /// coordinator, which SURVIVES the swap, so it stays wired without re-adding.
    /// Returns false if the remove/reload failed.
    @discardableResult
    func reloadStore() -> Bool {
        let coordinator = container.persistentStoreCoordinator
        // Drop live objects so nothing is "in use" during the store swap.
        container.viewContext.reset()
        do {
            for store in coordinator.persistentStores {
                try coordinator.remove(store)
            }
        } catch {
            Log.error("store reload: remove failed: \(error.localizedDescription)")
            return false
        }
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            Log.error("store reload: reload failed: \(loadError.localizedDescription)")
            return false
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // Content-free: no clip text, just the fact that a reload happened.
        Log.info("store reloaded to trigger a CloudKit import")
        return true
    }

    /// - Parameters:
    ///   - storeURL: SQLite location. Pass the on-disk
    ///     `…/Recallyx/Recallyx.sqlite`; omit for the default of an in-memory
    ///     store (used by callers that supply their own URL anyway).
    ///   - inMemory: when true, the store is created at `/dev/null` so nothing
    ///     touches disk — used by the hermetic test suite.
    ///   - cloudSyncEnabled: turns on CloudKit mirroring by attaching
    ///     `cloudKitContainerOptions` to the store description — but only when
    ///     the process is entitled (`hasEntitlement`), otherwise it stays a plain
    ///     local store to avoid the unentitled CloudKit crash. Off by default.
    ///   - hasEntitlement: injectable for tests; defaults to the real process
    ///     entitlement check.
    public init(
        storeURL: URL? = nil, inMemory: Bool = false, cloudSyncEnabled: Bool = false,
        hasEntitlement: Bool = PersistenceController.processHasCloudKitEntitlement,
        readOnly: Bool = false
    ) {
        let model = ClipModel.makeModel()
        container = NSPersistentCloudKitContainer(name: "Recallyx", managedObjectModel: model)

        let description = Self.makeStoreDescription(
            storeURL: storeURL, inMemory: inMemory, cloudSyncEnabled: cloudSyncEnabled,
            hasEntitlement: hasEntitlement, readOnly: readOnly
        )
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            // A failed store load is unrecoverable for the history backend;
            // surface it loudly rather than limping on a broken context.
            Log.error("Core Data store load failed: \(loadError.localizedDescription)")
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
