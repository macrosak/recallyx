import Foundation

/// On-disk clipboard history: `history.json` (the index) + `images/<id>.png`
/// (image payloads). Kept off UserDefaults because images make the store
/// megabytes-large. The in-memory `items` array is always ordered newest-first;
/// `add` inserts at the top, `bump` moves to the top.
///
/// Robustness mirrors AI Replace's `SettingsStore`: atomic writes (temp file +
/// rename), debounced saves, reseed-on-corrupt (the bad file is backed up), and
/// orphan reconciliation on launch.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []

    /// Retention cap — clips beyond this are evicted oldest-first. Changing it
    /// (from Settings) re-enforces immediately.
    var cap: Int {
        didSet {
            guard cap != oldValue else { return }
            enforceCap()
            didMutate()   // eviction must reach onChange so the menu count updates
        }
    }

    private let baseURL: URL
    private let imagesURL: URL
    private let indexURL: URL
    private let fm = FileManager.default
    private var saveTask: Task<Void, Never>?

    /// `onChange` fires after every mutation so the app can refresh the
    /// menu-bar count and any open panel.
    var onChange: (() -> Void)?

    /// - Parameters:
    ///   - baseURL: the store directory; defaults to
    ///     `~/Library/Application Support/Recallyx`. Tests pass a temp dir.
    init(baseURL: URL? = nil, cap: Int = 1000) {
        self.cap = cap
        let base = baseURL ?? Self.defaultBaseURL()
        self.baseURL = base
        self.imagesURL = base.appendingPathComponent("images", isDirectory: true)
        self.indexURL = base.appendingPathComponent("history.json")

        try? fm.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
        reconcileOrphans()
    }

    static func defaultBaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Recallyx", isDirectory: true)
    }

    // MARK: - Public API

    /// Insert a freshly captured clip, or — if identical content already exists
    /// (same `contentHash`) — bump that existing row to the top instead of
    /// inserting a duplicate. Returns the resulting item's id.
    @discardableResult
    func add(_ captured: CapturedClip) -> UUID {
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
                Log.error("history image write failed: \(error.localizedDescription)")
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
    func bump(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: idx)
        item.lastUsedAt = Date()
        items.insert(item, at: 0)
        didMutate()
    }

    func delete(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: idx)
        deleteImageFile(for: item)
        didMutate()
    }

    func clear() {
        for item in items { deleteImageFile(for: item) }
        items.removeAll()
        didMutate()
    }

    /// Absolute URL of an image item's PNG, or nil for text / missing file.
    func imageURL(for item: HistoryItem) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesURL.appendingPathComponent(filename)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else {
            items = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
            // Defensive re-sort: trust max(createdAt, lastUsedAt) over file order.
            items = decoded.sorted { $0.recency > $1.recency }
            Log.info("history loaded count=\(items.count)")
        } catch {
            Log.error("history decode failed: \(error.localizedDescription) — backing up and reseeding")
            let backup = indexURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: indexURL, to: backup)
            items = []
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            Self.persist(snapshot, to: indexURL)
        }
    }

    /// Flush any pending debounced write synchronously (call at shutdown).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Self.persist(items, to: indexURL)
    }

    private static func persist(_ items: [HistoryItem], to url: URL) {
        do {
            let data = try JSONEncoder().encode(items)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            // Atomic replace: rename over the live file. `replaceItemAt` falls
            // back to a plain move when there's no existing file.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Log.error("history persist failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func didMutate() {
        scheduleSave()
        onChange?()
    }

    private func enforceCap() {
        guard items.count > cap else { return }
        let overflow = items[cap...]
        for item in overflow { deleteImageFile(for: item) }
        items.removeLast(items.count - cap)
        Log.info("history evicted to cap=\(cap)")
    }

    private func deleteImageFile(for item: HistoryItem) {
        guard let url = imageURL(for: item) else { return }
        try? fm.removeItem(at: url)
    }

    /// On launch: delete `images/` files with no index entry, so abandoned PNGs
    /// (e.g. from a crash between image-write and index-save) don't accumulate.
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
