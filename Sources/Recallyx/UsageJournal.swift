import Foundation
import RecallyxCore

/// A **local-only, opt-in, off-by-default** record of how Recallyx is used, so
/// product decisions can be grounded in real behavior. Mirrors the other stores
/// (`@MainActor final class`). It holds the enabled flag + a file URL and
/// appends one JSON-Lines event per `log` call.
///
/// ## Privacy (these are the spec, not preferences)
/// - **Off by default.** Nothing is written unless `enabled` is set true.
/// - **Local only.** Appends to a file on disk. **No network code exists here at
///   all** — no `URLSession`, no sockets, no transmission of any kind.
/// - **Never clipboard contents.** Callers must never pass clip text, image
///   bytes, or clip file paths in `fields`. For search, log only `queryLength`
///   (an `Int`) — never the query characters. For errors, log a category
///   *string*, never the raw error message (which can echo user text / script
///   output).
/// - The user can **inspect and delete** the journal from Settings (Reveal in
///   Finder + Clear).
///
/// ## Storage / format
/// `~/Library/Application Support/Recallyx/usage.jsonl` — append-only JSON Lines,
/// one event per line: `{"ts": "<ISO8601 local>", "event": "<name>", …fields}`.
/// Fields are serialized with sorted keys for deterministic output.
///
/// ## Size cap (documented policy)
/// The file is bounded at `maxBytes` (2 MB). On an append that would push the
/// file past the cap, we **truncate from the front** — read the existing lines,
/// drop the oldest until the file (plus the new line) fits under `targetBytes`
/// (≈75% of the cap, so we don't re-trim on every subsequent write), then
/// rewrite the survivors and append. This keeps the *newest* events and never
/// lets the file grow unbounded. Simple, robust, no rotation files to manage.
@MainActor
final class UsageJournal {
    /// Master switch. When false, `log` no-ops on its very first line — nothing
    /// is opened, serialized, or written.
    var enabled: Bool

    /// Hard cap on the file size. A write that would exceed it triggers
    /// front-truncation down to `targetBytes`. `nonisolated` so the off-main
    /// append/truncate helpers can read them without actor hops.
    nonisolated static let maxBytes = 2 * 1024 * 1024          // 2 MB
    nonisolated static let targetBytes = (maxBytes * 3) / 4     // trim down to ~1.5 MB

    private let fileURL: URL
    /// Timestamp seam — injectable so tests are hermetic (no real wall clock).
    private let now: () -> Date

    /// The most recent off-main append task. Internal (not private) so tests can
    /// `await` the write to complete deterministically; production ignores it.
    var lastWrite: Task<Void, Never>?

    /// - Parameters:
    ///   - enabled: start state (production threads the persisted setting in).
    ///   - fileURL: the journal file; defaults to
    ///     `~/Library/Application Support/Recallyx/usage.jsonl`. Tests pass a
    ///     temp file.
    ///   - now: clock seam; defaults to `Date()`.
    init(
        enabled: Bool = false,
        fileURL: URL? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.enabled = enabled
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.now = now
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Recallyx", isDirectory: true)
            .appendingPathComponent("usage.jsonl")
    }

    /// ISO8601 in the *local* time zone (so time-of-day analysis matches the
    /// user's day). Stable across calls; no per-line allocation churn.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Logging

    /// Append one event line. **No-ops immediately when disabled** (the very
    /// first check), so logging is free when off. The serialization + file write
    /// happen off the main thread (a detached task) so logging never blocks UI.
    ///
    /// `fields` must contain only non-sensitive values — see the type docs.
    /// Values must be JSON-encodable (`String`, `Int`, `Bool`, `[String]`,
    /// `NSNull` for an explicit null, …). The reserved keys `ts` and `event` are
    /// set by the journal and must not appear in `fields`.
    func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }

        var object: [String: Any] = fields
        object["ts"] = Self.isoFormatter.string(from: now())
        object["event"] = event

        guard let line = Self.serialize(object) else {
            Log.error("usage journal: could not serialize event '\(event)'")
            return
        }

        let url = fileURL
        lastWrite = Task.detached(priority: .utility) {
            Self.append(line: line, to: url)
        }
    }

    /// Serialize one object to a single-line JSON string (sorted keys for
    /// determinism). Returns nil if the fields aren't JSON-encodable.
    private static func serialize(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        // JSONSerialization produces no embedded newlines for these flat objects,
        // so one object == one line is guaranteed.
        return string
    }

    /// Append `line` + "\n" to the file, creating parent dirs / the file as
    /// needed, front-truncating first if the result would exceed the cap.
    /// Runs off the main thread; all errors are swallowed (logging must never
    /// disrupt the app) — best effort.
    nonisolated private static func append(line: String, to url: URL) {
        let fm = FileManager.default
        let data = Data((line + "\n").utf8)

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let existingSize = (attrs[.size] as? Int) ?? 0
        if existingSize + data.count > maxBytes {
            truncateFromFront(at: url, makingRoomFor: data.count)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File doesn't exist yet (or couldn't be opened) — create it.
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Drop oldest lines until the file plus an incoming `incomingBytes` write
    /// fits under `targetBytes`, then rewrite the survivors atomically. Keeps the
    /// newest events. Best effort — a read/parse failure leaves the file as-is.
    nonisolated private static func truncateFromFront(at url: URL, makingRoomFor incomingBytes: Int) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Keep only complete lines; the trailing element after the last "\n" is "".
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        var total = lines.reduce(0) { $0 + ($1.utf8.count + 1) }  // +1 for each "\n"
        let budget = max(0, targetBytes - incomingBytes)
        while total > budget, !lines.isEmpty {
            let dropped = lines.removeFirst()
            total -= (dropped.utf8.count + 1)
        }

        let rebuilt = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? Data(rebuilt.utf8).write(to: url, options: .atomic)
    }

    // MARK: - User controls (Settings)

    /// Delete the journal file (the "Clear" button). Best effort.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The journal file URL (for "Reveal in Finder").
    var url: URL { fileURL }
}
