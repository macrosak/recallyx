import CoreData
import Foundation

/// A **read-only** view onto the live Recallyx history store, for out-of-process
/// readers (the `recallyx` CLI). It opens `…/Recallyx/Recallyx.sqlite` through a
/// `PersistenceController(readOnly: true)` — the store description sets
/// `isReadOnly`, so the coordinator rejects every write and this process can
/// never mutate or corrupt the file the running app owns. WAL journaling lets it
/// read alongside the app's concurrent writes.
///
/// Unlike `HistoryStore` this deliberately does **no** migration, orphan
/// reconciliation, cap enforcement, or remote-change observing — all of those
/// write to disk. It only fetches a recency-ordered snapshot and maps images to
/// their on-disk PNG path.
public final class HistoryReader {
    /// nil when the store file doesn't exist yet (the app never ran, or a fresh
    /// `RECALLYX_DATA_DIR`). A read-only store CANNOT create a missing file — it
    /// would error loudly — so we skip opening entirely and read as empty.
    private let persistence: PersistenceController?
    private let imagesURL: URL

    /// - Parameter baseURL: the store directory; defaults to
    ///   `~/Library/Application Support/Recallyx` (honoring `RECALLYX_DATA_DIR`
    ///   the same way the app does via the caller). Tests pass a temp dir.
    /// The default store directory, `~/Library/Application Support/Recallyx`.
    /// A `nonisolated` twin of `HistoryStore.defaultBaseURL()` (which is
    /// main-actor isolated) so the out-of-process reader can compute it off the
    /// main actor.
    public static func defaultBaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Recallyx", isDirectory: true)
    }

    public init(baseURL: URL? = nil, cloudSyncEnabled: Bool = false) {
        let base = baseURL ?? Self.defaultBaseURL()
        self.imagesURL = base.appendingPathComponent("images", isDirectory: true)
        let storeURL = base.appendingPathComponent("Recallyx.sqlite")
        if FileManager.default.fileExists(atPath: storeURL.path) {
            // Read-only, mirroring OFF: a sibling reader must never load a
            // mirrored store (unentitled crash) and must never write.
            self.persistence = PersistenceController(
                storeURL: storeURL, inMemory: false, cloudSyncEnabled: false, readOnly: true
            )
        } else {
            self.persistence = nil
        }
    }

    /// The full history, newest-first (recency = max(createdAt, lastUsedAt)).
    /// A fetch failure returns an empty array rather than throwing — the CLI
    /// surfaces "no clips" instead of a stack trace.
    public func items() -> [HistoryItem] {
        guard let persistence else { return [] }
        let ctx = persistence.viewContext
        var result: [HistoryItem] = []
        ctx.performAndWait {
            let request = ClipEntity.clipFetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "recency", ascending: false)]
            do {
                let rows = try ctx.fetch(request)
                result = rows.compactMap { $0.toItem() }.sorted { $0.recency > $1.recency }
            } catch {
                Log.error("history read failed: \(error.localizedDescription)")
                result = []
            }
        }
        return result
    }

    /// Absolute URL of an image item's PNG, or nil for text / no filename.
    public func imageURL(for item: HistoryItem) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesURL.appendingPathComponent(filename)
    }
}
