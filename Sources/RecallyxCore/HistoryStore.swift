import CoreData
import Foundation

/// Clipboard history backed by **Core Data** (`NSPersistentCloudKitContainer`
/// with mirroring OFF — a plain local SQLite store at
/// `…/Recallyx/Recallyx.sqlite`). Image payloads still live on disk as
/// `images/<id>.png`; only the filename is stored in the entity.
///
/// The public API is unchanged from the JSON era (`items`, `add`, `bump`,
/// `delete`, `clear`, `setPinned`, `cap`, `imageURL`, `flush`, `onChange`) — only
/// the backend swapped. The in-memory `items` array stays the canonical state
/// (always recency-ordered, newest-first); every mutation mirrors into Core
/// Data. Pinned-first ordering is applied at the panel layer.
///
/// Robustness mirrors the JSON era: the cap is enforced on load and on add,
/// pinned clips are exempt from eviction, and `images/` is reconciled against
/// the entities on launch. On first launch over an existing `history.json` (and
/// an empty store) the JSON is imported, then renamed to `history.json.bak`.
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [HistoryItem] = []

    /// Retention cap — clips beyond this are evicted oldest-first. Changing it
    /// (from Settings) re-enforces immediately.
    public var cap: Int {
        didSet {
            guard cap != oldValue else { return }
            enforceCap()
            didMutate()   // eviction must reach onChange so the menu count updates
        }
    }

    private let baseURL: URL
    private let imagesURL: URL
    private let indexURL: URL          // legacy history.json (migration source only)
    private let storeURL: URL          // Recallyx.sqlite
    private let fm = FileManager.default
    private let persistence: PersistenceController
    private var saveTask: Task<Void, Never>?

    /// `onChange` fires after every mutation so the app can refresh the
    /// menu-bar count and any open panel.
    public var onChange: (() -> Void)?

    /// - Parameters:
    ///   - baseURL: the store directory; defaults to
    ///     `~/Library/Application Support/Recallyx`. Tests pass a temp dir.
    ///   - inMemory: when true, the Core Data store is created in memory
    ///     (`/dev/null`) so tests stay hermetic. The base dir is still used for
    ///     image files and the JSON-migration source.
    public init(baseURL: URL? = nil, cap: Int = 1000, inMemory: Bool = false) {
        self.cap = cap
        let base = baseURL ?? Self.defaultBaseURL()
        self.baseURL = base
        self.imagesURL = base.appendingPathComponent("images", isDirectory: true)
        self.indexURL = base.appendingPathComponent("history.json")
        self.storeURL = base.appendingPathComponent("Recallyx.sqlite")

        try? fm.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        self.persistence = PersistenceController(storeURL: storeURL, inMemory: inMemory)

        var skipReconcile = loadFromStore()

        // One-time JSON → Core Data migration: only when the store is empty and a
        // legacy index exists. Guarded by store-empty so it never double-imports.
        if items.isEmpty {
            // A corrupt legacy JSON is backed up to `.corrupt-*` and leaves the
            // store empty; skip reconciliation so the PNGs the backup still names
            // survive next to it (parity with the JSON-era corrupt path).
            if importLegacyJSONIfNeeded() { skipReconcile = true }
        }

        // Skip reconciliation when we reseeded from a corrupt/failed store or a
        // corrupt legacy import: with `items` empty, reconcileOrphans() would
        // delete every PNG.
        if !skipReconcile { reconcileOrphans() }

        // `cap`'s didSet doesn't fire during init, so enforce here in case it was
        // lowered between launches. Persists synchronously (no onChange — listeners
        // aren't wired yet).
        enforceCapOnLoad()
    }

    public static func defaultBaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Recallyx", isDirectory: true)
    }

    // MARK: - Public API

    /// Insert a freshly captured clip, or — if identical content already exists
    /// (same `contentHash`) — bump that existing row to the top instead of
    /// inserting a duplicate. Returns the resulting item's id.
    @discardableResult
    public func add(_ captured: CapturedClip) -> UUID {
        if let idx = items.firstIndex(where: { $0.contentHash == captured.contentHash }) {
            var existing = items.remove(at: idx)
            existing.lastUsedAt = Date()
            items.insert(existing, at: 0)
            Log.debug("history dedupe-bump hash=\(captured.contentHash.prefix(8)) → top")
            didMutate()
            return existing.id
        }

        let id = UUID()
        var imageFilename: String?
        if captured.kind == .image, let data = captured.imageData {
            let filename = "\(id.uuidString).png"
            let url = imagesURL.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .atomic)
                imageFilename = filename
            } catch {
                // The PNG is the clip's entire payload — without it an image item
                // would be permanently broken and undisplayable. Drop the capture
                // rather than insert a corrupt row. The fresh id is returned but
                // never referenced (the watcher discards it for image clips).
                Log.error("history image write failed, dropping clip: \(error.localizedDescription)")
                return id
            }
        }

        let now = Date()
        let item = HistoryItem(
            id: id,
            kind: captured.kind,
            text: captured.text,
            imageFilename: imageFilename,
            preview: captured.preview,
            byteSize: captured.byteSize,
            sourceAppBundleID: captured.sourceAppBundleID,
            sourceAppName: captured.sourceAppName,
            sourceAppPath: captured.sourceAppPath,
            createdAt: now,
            lastUsedAt: now,
            contentHash: captured.contentHash,
            imageDimensions: captured.imageDimensions
        )
        items.insert(item, at: 0)
        Log.debug("history add kind=\(captured.kind.rawValue) id=\(id.uuidString.prefix(8)) count=\(items.count)")
        enforceCap()
        didMutate()
        return id
    }

    /// Move an existing item to the top and refresh its `lastUsedAt` — used when
    /// the user pastes a clip (the watcher's self-write guard prevents a dupe).
    public func bump(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: idx)
        item.lastUsedAt = Date()
        items.insert(item, at: 0)
        didMutate()
    }

    /// Toggle a clip's pinned flag. Pinned clips sort to the top of the panel
    /// list and are exempt from cap eviction. `items` stays in pure recency
    /// order internally — pinned-first ordering is applied at the panel layer.
    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned = pinned
        didMutate()
    }

    public func delete(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: idx)
        deleteImageFile(for: item)
        didMutate()
    }

    public func clear() {
        for item in items { deleteImageFile(for: item) }
        items.removeAll()
        didMutate()
    }

    /// Absolute URL of an image item's PNG, or nil for text / missing file.
    public func imageURL(for item: HistoryItem) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesURL.appendingPathComponent(filename)
    }

    // MARK: - Persistence (Core Data)

    /// Loads the entities into `items`, recency-ordered. Returns `true` only when
    /// the store failed to load and we reseeded empty (so `init` can skip orphan
    /// reconciliation and preserve the PNGs); `false` for a successful load and
    /// for the normal empty/fresh case.
    @discardableResult
    private func loadFromStore() -> Bool {
        let ctx = persistence.viewContext
        let request = ClipEntity.clipFetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "recency", ascending: false)]
        do {
            let rows = try ctx.fetch(request)
            // Map to value types; trust max(createdAt, lastUsedAt) over the stored
            // recency for the final sort (defensive, matches the JSON-era re-sort).
            items = rows.compactMap { $0.toItem() }.sorted { $0.recency > $1.recency }
            Log.info("history loaded count=\(items.count)")
            return false
        } catch {
            Log.error("history fetch failed: \(error.localizedDescription) — reseeding empty")
            items = []
            return true
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self.persist(snapshot)
        }
    }

    /// Flush any pending debounced write synchronously (call at shutdown).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist(items)
    }

    /// Reconcile the Core Data store to match the in-memory `items`: upsert each
    /// item by id, delete any rows whose id is no longer present. The in-memory
    /// array is the source of truth, so this keeps the store a faithful mirror
    /// without re-implementing the dedupe/cap/order logic in Core Data.
    private func persist(_ snapshot: [HistoryItem]) {
        let ctx = persistence.viewContext
        ctx.performAndWait {
            do {
                let request = ClipEntity.clipFetchRequest()
                let existing = try ctx.fetch(request)
                var byID: [UUID: ClipEntity] = [:]
                for row in existing {
                    if let rid = row.id { byID[rid] = row } else { ctx.delete(row) }
                }

                let liveIDs = Set(snapshot.map { $0.id })
                // Delete rows no longer in the snapshot.
                for (rid, row) in byID where !liveIDs.contains(rid) {
                    ctx.delete(row)
                }
                // Upsert each live item.
                for item in snapshot {
                    let entity = byID[item.id] ?? ClipEntity(context: ctx)
                    entity.apply(item)
                }

                if ctx.hasChanges { try ctx.save() }
            } catch {
                Log.error("history persist failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - One-time JSON → Core Data migration

    /// On first launch of the Core Data build: if a legacy `history.json` exists,
    /// decode it with the JSON-era logic, insert an entity per item (preserving
    /// ids/timestamps/pins/images), then rename `history.json` → `history.json.bak`.
    /// Idempotent: callers guard on `items.isEmpty`, and the `.bak` rename means a
    /// second run finds no `history.json` to import. A corrupt JSON is tolerated
    /// (backed up to `.corrupt-*`, store stays empty).
    ///
    /// Returns `true` when it hit the corrupt-JSON branch (so `init` can skip
    /// orphan reconciliation and preserve the PNGs the `.corrupt-*` backup names);
    /// `false` for a clean import and for the no-legacy-file case.
    @discardableResult
    private func importLegacyJSONIfNeeded() -> Bool {
        guard fm.fileExists(atPath: indexURL.path) else { return false }
        guard let data = try? Data(contentsOf: indexURL) else { return false }

        let decoded: [HistoryItem]
        do {
            decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
        } catch {
            Log.error("legacy history.json decode failed: \(error.localizedDescription) — backing up, store stays empty")
            let backup = indexURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: indexURL, to: backup)
            return true
        }

        items = decoded.sorted { $0.recency > $1.recency }
        persist(items)
        Log.info("migrated \(items.count) clip(s) from history.json → Core Data")

        // Rename the source so the import is one-shot. Don't delete — keep the
        // .bak as a safety net.
        let backup = indexURL.appendingPathExtension("bak")
        try? fm.removeItem(at: backup)   // overwrite a stale .bak if present
        do {
            try fm.moveItem(at: indexURL, to: backup)
        } catch {
            Log.error("history.json → .bak rename failed: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: - Internals

    private func didMutate() {
        scheduleSave()
        onChange?()
    }

    /// Evict the oldest *unpinned* items until within cap. Pinned clips stay put
    /// even if that leaves the store above cap.
    private func enforceCap() {
        guard items.count > cap else { return }
        var i = items.count - 1
        while items.count > cap && i >= 0 {
            if !items[i].isPinned {
                deleteImageFile(for: items[i])
                items.remove(at: i)
            }
            i -= 1
        }
        Log.info("history evicted to cap=\(cap)")
    }

    /// Cap enforcement during init: trim in memory and persist synchronously,
    /// without firing onChange (listeners aren't wired yet).
    private func enforceCapOnLoad() {
        let before = items.count
        enforceCap()
        if items.count != before { persist(items) }
    }

    private func deleteImageFile(for item: HistoryItem) {
        guard let url = imageURL(for: item) else { return }
        try? fm.removeItem(at: url)
    }

    /// On launch: delete `images/` files with no index entry, so abandoned PNGs
    /// (e.g. from a crash between image-write and store-save) don't accumulate.
    /// Index entries whose image file is missing are kept — the UI renders a
    /// placeholder for them.
    private func reconcileOrphans() {
        let referenced = Set(items.compactMap { $0.imageFilename })
        guard let files = try? fm.contentsOfDirectory(atPath: imagesURL.path) else { return }
        var removed = 0
        for file in files where !referenced.contains(file) {
            try? fm.removeItem(at: imagesURL.appendingPathComponent(file))
            removed += 1
        }
        if removed > 0 { Log.info("history reconcile: removed \(removed) orphan image file(s)") }
    }
}
