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
    private let cloudSyncEnabled: Bool
    private var saveTask: Task<Void, Never>?

    /// Ids the running app has mutated locally since the last successful save,
    /// and ids it has locally deleted. `persist` writes ONLY these — it never
    /// mirrors the whole in-memory array — so a CloudKit import that landed
    /// behind our back (a remote pin/add/delete on a clip we didn't touch) is
    /// NOT clobbered by our next local edit. This is the core of the sync-merge
    /// fix: the store is a shared, concurrently-written file, so a blind
    /// whole-array upsert re-exports stale fields the running app never saw.
    private var dirtyIDs: Set<UUID> = []
    private var deletedIDs: Set<UUID> = []

    /// Debounce + task for merging remote (CloudKit / other-coordinator) changes.
    private let remoteMergeDelay: TimeInterval
    private var mergeTask: Task<Void, Never>?
    private var remoteChangeObserver: NSObjectProtocol?

    /// `onChange` fires after every mutation so the app can refresh the
    /// menu-bar count and any open panel.
    public var onChange: (() -> Void)?

    /// - Parameters:
    ///   - baseURL: the store directory; defaults to
    ///     `~/Library/Application Support/Recallyx`. Tests pass a temp dir.
    ///   - inMemory: when true, the Core Data store is created in memory
    ///     (`/dev/null`) so tests stay hermetic. The base dir is still used for
    ///     image files and the JSON-migration source.
    ///   - cloudSyncEnabled: opt-in CloudKit mirroring (off by default). Read
    ///     once here at construction — toggling the setting takes effect on the
    ///     next launch, when the store is rebuilt.
    ///   - reconcileImages: when true (default, mac) launch prunes `images/` files
    ///     with no matching entity. iOS passes **false**: in sync phase 1 image
    ///     payloads don't sync, so a synced image clip has an entity but no local
    ///     PNG — reconciliation must not run there (an iOS-local image write path
    ///     could otherwise treat every not-yet-synced file as an orphan). Off also
    ///     means image entities lacking a local file are always kept.
    ///   - remoteMergeDelay: debounce before merging a batch of remote
    ///     (CloudKit / other-coordinator) changes. Defaults to ~1s; tests pass a
    ///     tiny value to keep the notification→merge path fast.
    public init(baseURL: URL? = nil, cap: Int = 1000, inMemory: Bool = false, cloudSyncEnabled: Bool = false, reconcileImages: Bool = true, remoteMergeDelay: TimeInterval = 1.0) {
        self.cap = cap
        let base = baseURL ?? Self.defaultBaseURL()
        self.baseURL = base
        self.imagesURL = base.appendingPathComponent("images", isDirectory: true)
        self.indexURL = base.appendingPathComponent("history.json")
        self.storeURL = base.appendingPathComponent("Recallyx.sqlite")
        self.cloudSyncEnabled = cloudSyncEnabled
        self.remoteMergeDelay = remoteMergeDelay

        try? fm.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        self.persistence = PersistenceController(storeURL: storeURL, inMemory: inMemory, cloudSyncEnabled: cloudSyncEnabled)

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
        // delete every PNG. iOS (reconcileImages: false) skips it always — its
        // image entities intentionally lack local files until image sync ships.
        //
        // **Skip it too when sync is on.** After sync, an entity imported from
        // another device references a PNG that never synced (image payloads stay
        // local this phase), so its local file is absent. Orphan reconciliation
        // must not treat a synced-in image row as garbage — the entity is kept and
        // the UI shows a placeholder, mirroring iOS (reconcileImages: false).
        if reconcileImages && !skipReconcile && !cloudSyncEnabled { reconcileOrphans() }

        // `cap`'s didSet doesn't fire during init, so enforce here in case it was
        // lowered between launches. Persists synchronously (no onChange — listeners
        // aren't wired yet).
        enforceCapOnLoad()

        // Learn about CloudKit imports / other-coordinator writes so `items` stays
        // live instead of frozen at launch.
        startObservingRemoteChanges()
    }

    deinit {
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
        }
    }

    /// Test seam: the persistent store coordinator that remote-change
    /// notifications are scoped to, and the on-disk SQLite URL. Lets tests write
    /// through a second container on the same file and post the notification the
    /// running app would receive from a CloudKit import. `internal` — invisible
    /// outside the module.
    var storeCoordinatorForTesting: NSPersistentStoreCoordinator {
        persistence.container.persistentStoreCoordinator
    }
    var storeURLForTesting: URL { storeURL }

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
            markDirty(existing.id)
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
            imageDimensions: captured.imageDimensions,
            sourceDeviceName: captured.sourceDeviceName,
            sourceDeviceType: captured.sourceDeviceType
        )
        items.insert(item, at: 0)
        Log.debug("history add kind=\(captured.kind.rawValue) id=\(id.uuidString.prefix(8)) count=\(items.count)")
        markDirty(id)
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
        markDirty(id)
        didMutate()
    }

    /// Toggle a clip's pinned flag. Pinned clips sort to the top of the panel
    /// list and are exempt from cap eviction. `items` stays in pure recency
    /// order internally — pinned-first ordering is applied at the panel layer.
    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned = pinned
        markDirty(id)
        didMutate()
    }

    /// Record the Apple Vision OCR transcript for an image clip (see
    /// `HistoryItem.ocrText`). `text` is trimmed; an empty/whitespace result is
    /// stored as the `""` sentinel ("OCRed, no text") so the backfill never
    /// revisits it. Content-free logging (length only). No-op if the id is gone
    /// or the value is unchanged — so a re-OCR (a dedupe-bump, or racing
    /// capture/backfill tasks) doesn't churn the dirty set or re-export via sync.
    public func setOCRText(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard items[idx].ocrText != normalized else { return }
        items[idx].ocrText = normalized
        markDirty(id)
        Log.debug("ocr set id=\(id.uuidString.prefix(8)) len=\(normalized.count)")
        didMutate()
    }

    /// The backfill work list: image clips that have **never** been OCRed
    /// (`ocrText == nil`) and whose PNG still exists locally, newest first. The
    /// `""` sentinel and any non-nil transcript are excluded, so a re-launch just
    /// continues with the remaining nils — each `setOCRText` shrinks the list.
    /// Content-free (ids + file URLs only).
    public func ocrBackfillCandidates() -> [(id: UUID, imageURL: URL)] {
        items.compactMap { item in
            guard item.kind == .image, item.ocrText == nil,
                  let url = imageURL(for: item),
                  fm.fileExists(atPath: url.path) else { return nil }
            return (id: item.id, imageURL: url)
        }
    }

    public func delete(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: idx)
        deleteImageFile(for: item)
        markDeleted(id)
        didMutate()
    }

    public func clear() {
        for item in items { deleteImageFile(for: item); markDeleted(item.id) }
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
        // Overwrite any cached property values with the store's current values, so
        // a re-read after a remote import reflects the imported changes (e.g. a pin
        // flag another device flipped) rather than this context's stale snapshot.
        request.shouldRefreshRefetchedObjects = true
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
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self.persist()
        }
    }

    /// Flush any pending debounced write synchronously (call at shutdown, and
    /// before a remote-change merge so in-flight local edits are written first).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    /// Write the pending local mutations to Core Data — and **only** those.
    ///
    /// Upserts the entities in `dirtyIDs` (from the current `items`) and deletes
    /// the entities in `deletedIDs`; it never touches any other row. This is a
    /// deliberate change from a whole-array mirror: the SQLite store is written
    /// concurrently by CloudKit imports (and any sibling coordinator), so a blind
    /// upsert of the entire in-memory array would re-export fields the running app
    /// never saw — silently reverting a remote pin/add/delete on a clip the user
    /// didn't touch. Scoping every write to the locally-dirtied ids is what lets
    /// the debounced remote-merge (`mergeRemoteChanges`) safely coexist with local
    /// edits.
    private func persist() {
        guard !dirtyIDs.isEmpty || !deletedIDs.isEmpty else { return }
        let dirty = dirtyIDs
        let deleted = deletedIDs
        dirtyIDs.removeAll()
        deletedIDs.removeAll()

        var itemsByID: [UUID: HistoryItem] = [:]
        for item in items { itemsByID[item.id] = item }

        let ctx = persistence.viewContext
        var failed = false
        ctx.performAndWait {
            do {
                let touched = dirty.union(deleted)
                let request = ClipEntity.clipFetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", touched as NSSet)
                let existing = try ctx.fetch(request)
                var byID: [UUID: ClipEntity] = [:]
                for row in existing where row.id != nil { byID[row.id!] = row }

                // Deletes: only ids we locally removed. A remotely-deleted row
                // simply isn't in `touched`, so we never resurrect it.
                for id in deleted {
                    if let row = byID[id] { ctx.delete(row) }
                }
                // Upserts: only ids we locally mutated. An id that's dirty but no
                // longer in `items` (evicted after the mark) is skipped — its
                // delete mark, if any, already handled removal.
                for id in dirty {
                    guard let item = itemsByID[id] else { continue }
                    let entity = byID[id] ?? ClipEntity(context: ctx)
                    entity.apply(item)
                }

                if ctx.hasChanges { try ctx.save() }
            } catch {
                Log.error("history persist failed: \(error.localizedDescription)")
                failed = true
            }
        }
        // On failure, re-queue the ids so the next flush retries rather than
        // dropping the edits.
        if failed {
            dirtyIDs.formUnion(dirty)
            deletedIDs.formUnion(deleted)
        }
    }

    private func markDirty(_ id: UUID) {
        dirtyIDs.insert(id)
        deletedIDs.remove(id)   // a re-add supersedes a pending delete
    }

    private func markDeleted(_ id: UUID) {
        deletedIDs.insert(id)
        dirtyIDs.remove(id)     // a delete supersedes a pending upsert
    }

    // MARK: - Remote-change merge (CloudKit / other coordinators)

    /// Observe `.NSPersistentStoreRemoteChange` (posted because the store
    /// description enables history tracking + remote-change notifications). Each
    /// notification means another coordinator — the CloudKit mirroring delegate,
    /// or a sibling process — committed a transaction to our SQLite file, so the
    /// in-memory `items` are stale and must be re-read.
    private func startObservingRemoteChanges() {
        let coordinator = persistence.container.persistentStoreCoordinator
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: coordinator,
            queue: nil
        ) { [weak self] _ in
            // The notification can arrive on any queue; hop to the main actor.
            Task { @MainActor in self?.scheduleRemoteMerge() }
        }
    }

    /// Debounce a burst of remote-change notifications (a single import can post
    /// several) into one merge.
    private func scheduleRemoteMerge() {
        mergeTask?.cancel()
        let delay = remoteMergeDelay
        mergeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.mergeRemoteChanges()
        }
    }

    /// Flush pending local edits, then re-read the store and rebuild `items`,
    /// firing `onChange`. `internal` (not `private`) so tests can drive it
    /// deterministically after writing through a second container.
    func mergeRemoteChanges() {
        // Write any in-flight local edits FIRST, so re-reading the store doesn't
        // lose them — and, thanks to the dirty-set `persist`, without clobbering
        // the remote changes we're about to merge in.
        flush()

        let oldIDs = Set(items.map { $0.id })
        reloadItemsFromStore()
        let newIDs = Set(items.map { $0.id })
        let added = newIDs.subtracting(oldIDs).count
        let removed = oldIDs.subtracting(newIDs).count
        // Content-free: counts only, never clip text.
        Log.info("history remote-change merge: +\(added) -\(removed) total=\(items.count)")
        onChange?()
    }

    /// Re-fetch entities into `items`. Unlike `loadFromStore`, a transient fetch
    /// error keeps the current `items` rather than reseeding empty — a hiccup
    /// mid-session must not wipe the live history.
    private func reloadItemsFromStore() {
        let ctx = persistence.viewContext
        let request = ClipEntity.clipFetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "recency", ascending: false)]
        request.shouldRefreshRefetchedObjects = true
        do {
            let rows = try ctx.fetch(request)
            items = rows.compactMap { $0.toItem() }.sorted { $0.recency > $1.recency }
        } catch {
            Log.error("history reload failed: \(error.localizedDescription) — keeping current items")
        }
    }

    // MARK: - Explicit CloudKit refresh (pull-to-refresh / panel-open kick)

    /// Whether CloudKit mirroring is live for this store (the `iCloudSyncEnabled`
    /// opt-in AND the process entitled). The iOS pull-to-refresh and the mac
    /// panel-open kick both no-op when this is false, so their UI stays instant
    /// and side-effect-free with sync off / in an unentitled build.
    public var isCloudSyncActive: Bool { persistence.isMirroringActive }

    /// Last time `refreshFromCloud` actually reloaded the store — drives the
    /// mac's `minInterval` throttle.
    private var lastCloudRefresh: Date?

    /// Pure rate-limit decision for `refreshFromCloud`: allow when nothing has
    /// refreshed yet, or the last refresh was at least `minInterval` ago.
    /// Extracted so the throttle is unit-testable without a live/entitled store.
    public static func shouldRefresh(lastRefresh: Date?, now: Date, minInterval: TimeInterval) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= minInterval
    }

    /// Best-effort force a CloudKit pull. Flushes pending local writes, then
    /// reloads the persistent store so `NSPersistentCloudKitContainer` re-runs its
    /// import (there is no public fetch-now API — see `PersistenceController.reloadStore`).
    ///
    /// No-op — returns false — when mirroring is inactive (sync off / unentitled)
    /// or the last refresh was < `minInterval` ago (the mac throttles the frequent
    /// ⌘⇧V opens; iOS passes 0 for a deliberate pull). The import itself is async;
    /// its downloaded rows land in `items` via the remote-change observer's
    /// debounced merge, or via `refreshItemsFromStore` once a caller has awaited
    /// the import's completion. Returns true iff a reload actually fired.
    @discardableResult
    public func refreshFromCloud(minInterval: TimeInterval = 0, now: Date = Date()) -> Bool {
        guard persistence.isMirroringActive else { return false }
        guard Self.shouldRefresh(lastRefresh: lastCloudRefresh, now: now, minInterval: minInterval) else { return false }
        flush()
        guard persistence.reloadStore() else { return false }
        lastCloudRefresh = now
        // The reload's own import hasn't run yet; re-read the (unchanged) local
        // rows so `items` is backed by the fresh context. New remote rows arrive
        // later via the remote-change merge.
        reloadItemsFromStore()
        onChange?()
        return true
    }

    /// Re-read the store into `items` and fire `onChange`. iOS calls this right
    /// after a pull-to-refresh's import completes so the freshly-imported rows
    /// show the moment the spinner ends, rather than waiting out the ~1s debounced
    /// remote-change merge.
    public func refreshItemsFromStore() {
        reloadItemsFromStore()
        onChange?()
    }

    /// Test seam: run the store remove/re-add round-trip directly, bypassing the
    /// mirroring gate (off in the unentitled test process), to verify `items`
    /// survive a reload. `internal` — invisible outside the module.
    func reloadStoreForTesting() {
        flush()
        _ = persistence.reloadStore()
        reloadItemsFromStore()
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
        for item in items { markDirty(item.id) }
        persist()
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
                markDeleted(items[i].id)
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
        enforceCap()   // marks the evicted ids deleted
        if items.count != before { persist() }
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
