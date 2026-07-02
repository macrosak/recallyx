import Foundation

/// Pure, `nonisolated` display-order helper shared by every view layer.
///
/// The store keeps `items` in pure recency order internally; the pinned-first
/// ordering is applied wherever clips enter a view. The mac `HistoryPanelViewModel`
/// and the iOS list VM both need the *same* order, so the ~10-line sort lives here
/// (unit-testable without a UI). `HistoryPanelViewModel.ordered` delegates to it.
public enum HistoryOrdering {
    /// Pinned clips first, then by recency (newest first).
    ///
    /// Stable: the enumerated index breaks ties so equal-recency items keep their
    /// incoming (store recency) order rather than being shuffled by an unstable
    /// sort.
    public static func pinnedFirstByRecency(_ items: [HistoryItem]) -> [HistoryItem] {
        items.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }  // pinned first
            if a.element.recency != b.element.recency { return a.element.recency > b.element.recency }  // then newest
            return a.offset < b.offset
        }.map(\.element)
    }
}
