import CoreData
import Foundation

/// Wraps an `NSPersistentCloudKitContainer` for the history store. CloudKit
/// mirroring is **opt-in**: it is enabled only when `cloudSyncEnabled` is true
/// (driven by the `iCloudSyncEnabled` setting, off by default). When off we
/// never set `cloudKitContainerOptions`, so the container behaves as a plain
/// local SQLite store (no entitlement / Apple account needed). When on, the
/// store mirrors to the CloudKit container derived from the public bundle id —
/// which only actually reaches iCloud in a team-signed build carrying the
/// matching entitlement (the ad-hoc `bundle.sh` build stays inert).
///
/// The model is built programmatically (`ClipModel.makeModel()`), so no
/// `.xcdatamodeld` and no Xcode are required — the package stays CLT-buildable.
public final class PersistenceController {
    /// CloudKit container id — derived from the PUBLIC bundle id, so it carries
    /// no team identifier and is safe to hardcode/commit (mirrors the value in
    /// the committed entitlements file + `project.yml`).
    public static let cloudKitContainerIdentifier = "iCloud.io.github.macrosak.recallyx"

    /// Pure helper (unit-testable without loading a store): the CloudKit options
    /// to attach to the store description, or nil when sync is off.
    public static func cloudKitOptions(enabled: Bool) -> NSPersistentCloudKitContainerOptions? {
        enabled
            ? NSPersistentCloudKitContainerOptions(containerIdentifier: cloudKitContainerIdentifier)
            : nil
    }

    /// Builds the store description **without loading a store** — so a test can
    /// assert the mirroring gate (`cloudKitContainerOptions` set iff enabled)
    /// without ever spinning up the real CloudKit mirroring delegate (loading a
    /// mirrored store in an unentitled test process crashes in PushKit).
    public static func makeStoreDescription(
        storeURL: URL? = nil, inMemory: Bool = false, cloudSyncEnabled: Bool = false
    ) -> NSPersistentStoreDescription {
        let url: URL
        if inMemory {
            url = URL(fileURLWithPath: "/dev/null")
        } else {
            url = storeURL ?? URL(fileURLWithPath: "/dev/null")
        }
        let description = NSPersistentStoreDescription(url: url)
        // Opt-in CloudKit mirroring. nil (the default) keeps the store purely
        // local — no entitlement or iCloud account needed.
        description.cloudKitContainerOptions = cloudKitOptions(enabled: cloudSyncEnabled)
        // WAL is the SQLite default; spelled out so a future read-only MCP
        // reader (separate process) can read alongside the app's writes.
        description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)
        return description
    }

    public let container: NSPersistentCloudKitContainer

    /// `viewContext` runs on the main queue; the store reads through it.
    public var viewContext: NSManagedObjectContext { container.viewContext }

    /// - Parameters:
    ///   - storeURL: SQLite location. Pass the on-disk
    ///     `…/Recallyx/Recallyx.sqlite`; omit for the default of an in-memory
    ///     store (used by callers that supply their own URL anyway).
    ///   - inMemory: when true, the store is created at `/dev/null` so nothing
    ///     touches disk — used by the hermetic test suite.
    ///   - cloudSyncEnabled: turns on CloudKit mirroring by attaching
    ///     `cloudKitContainerOptions` to the store description. Off by default.
    public init(storeURL: URL? = nil, inMemory: Bool = false, cloudSyncEnabled: Bool = false) {
        let model = ClipModel.makeModel()
        container = NSPersistentCloudKitContainer(name: "Recallyx", managedObjectModel: model)

        let description = Self.makeStoreDescription(
            storeURL: storeURL, inMemory: inMemory, cloudSyncEnabled: cloudSyncEnabled
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
