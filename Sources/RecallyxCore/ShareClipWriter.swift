import CoreData
import Foundation

/// A **lean, single-clip writer** for the iOS Share Extension.
///
/// The extension runs in its own short-lived process with a tight memory ceiling
/// (~120 MB) and must save a shared clip fast, so it deliberately does **not**
/// use `HistoryStore`: that type is `@MainActor` and loads the *entire* history
/// into memory (fine for the app, wasteful and risky in an extension). This
/// writer opens the app-group Core Data store, does one dedupe fetch, inserts (or
/// bumps) exactly one row, saves, and returns — never materializing the rest of
/// the history.
///
/// **Why it must NOT enable CloudKit (`cloudSyncEnabled: false`).** Loading a
/// CloudKit-mirrored store from a secondary/short-lived process is the documented
/// crash/conflict zone (the mirroring delegate expects to own the store). The
/// extension therefore opens a plain **local** store. That is safe *and* still
/// syncs, because of persistent history:
///
/// - `PersistenceController.makeStoreDescription` sets `NSPersistentHistoryTrackingKey`
///   and `NSPersistentStoreRemoteChangeNotificationPostOptionKey` on **every**
///   store (local or mirrored). So the extension's insert is recorded as a
///   persistent-history transaction on the shared SQLite file.
/// - The **main app** (running, CloudKit-mirrored, entitled) owns the mirror.
///   `NSPersistentCloudKitContainer` exports local changes by processing that
///   shared persistent history — regardless of which process wrote them — so the
///   extension's transaction is uploaded to CloudKit and reaches the fleet.
/// - The main app's `HistoryStore` also observes `.NSPersistentStoreRemoteChange`
///   (posted for a sibling-process write to the same file), debounce-merges via
///   `mergeRemoteChanges`, and surfaces the new clip live in the UI.
/// - If the app is **not** running when the share happens, nothing is lost: the
///   transaction sits in persistent history and is exported the next time the app
///   launches and its container processes history.
///
/// The dedupe/bump behavior mirrors `HistoryStore.add`: a shared string whose
/// `contentHash` already exists bumps that row's recency to now instead of
/// inserting a duplicate.
public final class ShareClipWriter {
    private let persistence: PersistenceController

    /// Standard app-group container id (shared with the mac + iOS app so all
    /// three processes reach the same Core Data store).
    public static let defaultAppGroupID = "group.io.github.macrosak.recallyx"

    /// Resolve the shared app-group store directory (`…/<container>/Recallyx`),
    /// or `nil` when the container can't be resolved (an unprovisioned build).
    public static func appGroupBaseURL(groupID: String = defaultAppGroupID) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Recallyx", isDirectory: true)
    }

    /// Open the store at `baseURL/Recallyx.sqlite`. Always **local-only**
    /// (`cloudSyncEnabled: false`) — see the type doc for why the extension must
    /// never load a mirrored store.
    ///
    /// - Parameters:
    ///   - baseURL: the store directory (pass `appGroupBaseURL()` in the extension).
    ///   - inMemory: hermetic-test seam (`/dev/null` store).
    public init(baseURL: URL, inMemory: Bool = false) {
        if !inMemory {
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
        let storeURL = baseURL.appendingPathComponent("Recallyx.sqlite")
        self.persistence = PersistenceController(
            storeURL: storeURL, inMemory: inMemory, cloudSyncEnabled: false
        )
    }

    /// Test seam: inject an already-built controller (e.g. sharing a temp store
    /// with a `HistoryStore` in the same test).
    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    /// The result of a `save`, mirroring `HistoryStore.add`'s two happy paths plus
    /// a failure case.
    public enum Outcome: String, Equatable, Sendable {
        /// A new row was inserted.
        case inserted
        /// Identical content already existed; its recency was bumped to now.
        case bumped
        /// Nothing was written (a Core Data error).
        case failed
    }

    /// Save one shared clip. If a row with the same `contentHash` exists it is
    /// **bumped** (recency → `now`, matching `HistoryStore.add`); otherwise a new
    /// row is inserted. Runs entirely on a private background context — never
    /// touches the main queue — so it is safe to call off the main thread.
    @discardableResult
    public func save(_ captured: CapturedClip, now: Date = Date()) -> Outcome {
        let ctx = persistence.container.newBackgroundContext()
        // Duplicate-content edits arriving from other coordinators should lose to
        // our explicit write; the store is otherwise single-writer here.
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        var outcome: Outcome = .failed
        ctx.performAndWait {
            let request = ClipEntity.clipFetchRequest()
            request.predicate = NSPredicate(format: "contentHash == %@", captured.contentHash)
            request.fetchLimit = 1
            do {
                if let existing = try ctx.fetch(request).first {
                    // Dedupe-bump: keep createdAt, refresh lastUsedAt + recency.
                    existing.lastUsedAt = now
                    existing.recency = max(existing.createdAt ?? now, now)
                    outcome = .bumped
                } else {
                    let entity = ClipEntity(context: ctx)
                    entity.apply(Self.item(from: captured, now: now))
                    outcome = .inserted
                }
                if ctx.hasChanges { try ctx.save() }
            } catch {
                // Content-free: never logs clip text.
                Log.error("share clip save failed: \(error.localizedDescription)")
                outcome = .failed
            }
        }
        if outcome != .failed {
            Log.info("share clip \(outcome.rawValue) hash=\(captured.contentHash.prefix(8))")
        }
        return outcome
    }

    /// Build the stored `HistoryItem` for a fresh capture (fresh id, `createdAt ==
    /// lastUsedAt == now`), matching `HistoryStore.add`'s insert path.
    private static func item(from captured: CapturedClip, now: Date) -> HistoryItem {
        HistoryItem(
            id: UUID(),
            kind: captured.kind,
            text: captured.text,
            imageFilename: nil,
            preview: captured.preview,
            byteSize: captured.byteSize,
            sourceAppBundleID: captured.sourceAppBundleID,
            sourceAppName: captured.sourceAppName,
            sourceAppPath: captured.sourceAppPath,
            createdAt: now,
            lastUsedAt: now,
            contentHash: captured.contentHash,
            imageDimensions: captured.imageDimensions,
            sourceDeviceName: captured.sourceDeviceName,
            sourceDeviceType: captured.sourceDeviceType
        )
    }
}
