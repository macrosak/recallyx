import Foundation

/// A sync error, reduced to a **content-free category** (a CKError code name or
/// an `NSError` domain#code) plus the time it happened. Never carries a
/// `localizedDescription` — a CloudKit error's message can echo record content.
public struct SyncActivityError: Equatable, Sendable {
    public let category: String
    public let at: Date

    public init(category: String, at: Date) {
        self.category = category
        self.at = at
    }
}

/// Pure formatter for the one-line "Last sync" status shown under the iCloud
/// toggle (mac Settings + menu bar) and on iOS. Returns `nil` when there's
/// nothing to say yet (never synced, no error) so callers can show their own
/// "waiting for first sync" placeholder or hide the row.
///
/// Shapes:
/// - never synced, no error → `nil`
/// - export only            → `Last sync: ↑ 2 min ago`
/// - import only            → `Last sync: ↓ 5 min ago`
/// - both                   → `Last sync: ↑ 2 min ago · ↓ 5 min ago`
/// - error is the latest event → `Sync error: <category> · 1 min ago`
///
/// The error only wins when it's at least as recent as both successes — a later
/// successful export/import supersedes an older failure.
public enum SyncStatusLine {
    public static func text(
        lastExport: Date?,
        lastImport: Date?,
        lastError: SyncActivityError?,
        now: Date = Date()
    ) -> String? {
        if let lastError, isErrorLatest(lastError, lastExport: lastExport, lastImport: lastImport) {
            return "Sync error: \(lastError.category) · \(ClipTime.relative(lastError.at, now: now))"
        }

        var parts: [String] = []
        if let lastExport { parts.append("↑ \(ClipTime.relative(lastExport, now: now))") }
        if let lastImport { parts.append("↓ \(ClipTime.relative(lastImport, now: now))") }
        guard !parts.isEmpty else { return nil }
        return "Last sync: \(parts.joined(separator: " · "))"
    }

    /// The error supersedes the success lines only when no success is strictly
    /// newer than it.
    static func isErrorLatest(
        _ error: SyncActivityError,
        lastExport: Date?,
        lastImport: Date?
    ) -> Bool {
        if let lastExport, lastExport > error.at { return false }
        if let lastImport, lastImport > error.at { return false }
        return true
    }
}
