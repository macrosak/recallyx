import Foundation

/// A **local-only, content-free** rotating file sink for `Log`. macOS does not
/// persist info-level `os_log` to disk, so without this a bug leaves no trace
/// unless a `log stream` happened to be running. `FileLog` mirrors every `Log.*`
/// message to `~/Library/Logs/Recallyx/recallyx.log` so the log is already on
/// disk when the user reports a problem.
///
/// ## Privacy (these are the spec, not preferences)
/// - **Local only.** Appends to a file on disk. **No network code exists here at
///   all** — no `URLSession`, no sockets, no transmission of any kind.
/// - **Content-free.** The sink writes exactly the strings `Log` is given. The
///   contract (enforced at the call sites, audited in the PR that added this) is
///   that those strings never contain clip text, image bytes, or clip file
///   paths — diagnostics log lengths / categories / counts, never raw user
///   content. This sink adds no content of its own; it only timestamps + writes.
/// - **On by default.** The whole point is to capture the bug when it happens.
///   It can be disabled (`enabled = false`) and inspected / deleted from
///   Settings (Reveal in Finder + Clear).
///
/// ## Storage / format
/// `~/Library/Logs/Recallyx/recallyx.log` — append-only plain text, one line per
/// `Log.*` call, each prefixed with a local ISO8601 timestamp:
/// `2026-06-24T10:11:12+02:00 [recallyx] <message>`.
///
/// ## Size cap (2-file rotation)
/// When an append would push `recallyx.log` past `maxBytes` (2 MB), the current
/// file is rotated to `recallyx.log.1` (replacing any previous `.1`) and a fresh
/// `recallyx.log` is started. Total on-disk footprint is bounded at
/// `2 × maxBytes` (~4 MB). Rotation is simpler and cheaper than read-rewrite
/// front-truncation for a chatty line logger — a rename is O(1) and doesn't read
/// the whole file on the hot path.
///
/// All writes happen **off the main thread** (a detached task) so logging never
/// blocks the UI. Writes are serialized through a single global actor so
/// concurrent `Log.*` calls don't interleave or race the rotation.
public final class FileLog: @unchecked Sendable {
    /// Per-file cap; rotation kicks in past this. Total footprint is `2 ×`.
    public static let maxBytes = 2 * 1024 * 1024   // 2 MB

    /// Master switch. On by default (the point is to capture bugs unattended).
    /// When false, `write` no-ops on its very first line.
    private let _enabled = ManagedAtomicBool(true)
    public var enabled: Bool {
        get { _enabled.value }
        set { _enabled.value = newValue }
    }

    private let fileURL: URL
    /// Timestamp seam — injectable so tests are hermetic (no real wall clock).
    private let now: () -> Date

    /// The shared production sink. `Log` writes through this. Honors
    /// `RECALLYX_DATA_DIR` so debug runs write to the scratch dir.
    public static let shared = FileLog()

    /// - Parameters:
    ///   - enabled: start state (production threads the persisted setting in).
    ///   - fileURL: the log file; defaults to
    ///     `~/Library/Logs/Recallyx/recallyx.log`. Tests pass a temp file.
    ///   - now: clock seam; defaults to `Date()`.
    public init(
        enabled: Bool = true,
        fileURL: URL? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self._enabled.value = enabled
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.now = now
    }

    /// `~/Library/Logs/Recallyx/recallyx.log`, or `<RECALLYX_DATA_DIR>/recallyx.log`
    /// when the env override is set (mirrors the history store / usage journal so
    /// debug runs stay isolated).
    public static func defaultFileURL() -> URL {
        if let dataDir = ProcessInfo.processInfo.environment["RECALLYX_DATA_DIR"] {
            return URL(fileURLWithPath: dataDir, isDirectory: true)
                .appendingPathComponent("recallyx.log")
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Recallyx", isDirectory: true)
        return logs.appendingPathComponent("recallyx.log")
    }

    /// ISO8601 in the *local* time zone, so the timestamps line up with the
    /// user's day when they report a bug. Stable across calls.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The most recent off-main append task. `public` so tests can `await` the
    /// write to complete deterministically; production ignores it.
    public private(set) var lastWrite: Task<Void, Never>?

    // MARK: - Writing

    /// Append one already-formatted `Log` line (no timestamp yet). **No-ops
    /// immediately when disabled.** The timestamp prefix is added here; the file
    /// write + rotation happen off the main thread so logging never blocks UI.
    public func write(_ message: String) {
        guard enabled else { return }
        let stamped = "\(Self.isoFormatter.string(from: now())) \(message)\n"
        let url = fileURL
        lastWrite = Task.detached(priority: .utility) {
            await FileLogWriter.shared.append(stamped, to: url)
        }
    }

    // MARK: - User controls (Settings)

    /// Delete the log file and its rotated sibling (the "Clear" button). Best
    /// effort. Awaits any in-flight write first so a clear isn't immediately
    /// re-created by a queued append.
    public func clear() async {
        await lastWrite?.value
        await FileLogWriter.shared.remove(fileURL)
    }

    /// The current log file URL (for "Reveal in Finder").
    public var url: URL { fileURL }
}

/// Serializes all file writes/rotation/removal so concurrent `Log.*` calls never
/// interleave a line or race the rename. A dedicated global actor (not the main
/// actor) keeps the work off the UI thread.
private actor FileLogWriter {
    static let shared = FileLogWriter()

    /// Append `line` to `url`, creating parent dirs / the file as needed,
    /// rotating first if the result would exceed the cap. Best effort — all
    /// errors are swallowed (logging must never disrupt the app).
    func append(_ line: String, to url: URL) {
        let fm = FileManager.default
        let data = Data(line.utf8)

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let existingSize = (attrs[.size] as? Int) ?? 0
        if existingSize > 0, existingSize + data.count > FileLog.maxBytes {
            rotate(url)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Rename `recallyx.log` → `recallyx.log.1` (replacing any previous `.1`),
    /// leaving room for a fresh primary file. Best effort.
    private func rotate(_ url: URL) {
        let fm = FileManager.default
        let rotated = url.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    /// Remove both the primary file and its rotated sibling.
    func remove(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: url.appendingPathExtension("1"))
    }
}

/// A tiny lock-guarded atomic Bool — the package has zero deps and can't pull in
/// swift-atomics, and `enabled` is flipped from the main actor but read on the
/// detached write task. A plain `os_unfair_lock` wrapper is enough.
private final class ManagedAtomicBool: @unchecked Sendable {
    private var _value: Bool
    private let lock = NSLock()
    init(_ value: Bool = false) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
