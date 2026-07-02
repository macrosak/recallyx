import Foundation

/// Pure, `nonisolated` display helpers for the iOS clip list — filter compose,
/// row-subtitle formatting, and the image-placeholder title. The SwiftUI layer
/// stays a thin shell; all the branching logic lives here so it's unit-testable
/// without a simulator (mirrors `HistoryOrdering` / `HistoryPanelViewModel`'s
/// pure statics).
public enum ClipListDisplay {
    /// The list shown for a given search query.
    ///
    /// - Empty query → `pinnedFirstByRecency` (same order as the mac panel).
    /// - Non-empty → the sync fuzzy pass over the same ordered list. `rank` is a
    ///   stable filter, so pinned-first-then-recency order is preserved. (The mac
    ///   panel's async deep-substring pass is intentionally skipped for the MVP.)
    public static func filter(_ items: [HistoryItem], query: String) -> [HistoryItem] {
        let ordered = HistoryOrdering.pinnedFirstByRecency(items)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ordered }
        return FuzzyMatcher.rank(ordered, query: trimmed)
    }

    /// The row's secondary line: source-app name and relative capture time joined
    /// by a middle dot. Falls back to just the time when the app is unknown.
    public static func rowSubtitle(for item: HistoryItem, now: Date = Date()) -> String {
        let time = ClipTime.relative(item.recency, now: now)
        if let app = item.sourceAppName, !app.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(app) · \(time)"
        }
        return time
    }

    /// Title for an image-clip row/detail placeholder. Image payloads don't sync
    /// yet, so on iOS an image clip has metadata but no local PNG.
    /// e.g. `Image · 800×600`, or just `Image` when dimensions are unknown.
    public static func imagePlaceholderTitle(for item: HistoryItem) -> String {
        if let dims = item.imageDimensions, !dims.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Image · \(dims)"
        }
        return "Image"
    }
}
