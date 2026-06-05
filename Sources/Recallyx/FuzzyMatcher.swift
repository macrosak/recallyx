import Foundation

/// Subsequence fuzzy matching with ranking. A query matches a candidate when its
/// characters appear in order (case-insensitive). Ranking, best first:
/// exact > prefix > contiguous substring > scattered subsequence. Returns `nil`
/// when there's no match at all.
enum FuzzyMatcher {
    static func score(_ candidate: String, query: String) -> Int? {
        let q = query.lowercased()
        guard !q.isEmpty else { return 0 }
        let c = candidate.lowercased()

        if c == q { return 10_000 }
        if c.hasPrefix(q) { return 5_000 - candidate.count }
        if let range = c.range(of: q) {
            // Contiguous substring — earlier is better.
            let offset = c.distance(from: c.startIndex, to: range.lowerBound)
            return 2_000 - offset
        }
        return subsequenceScore(c, q)
    }

    /// Filter history items by a fuzzy query against their text/preview and
    /// source-app name, **preserving the input order** (recency). The query only
    /// decides what's kept, never how it's sorted — the list always reads newest
    /// first, matching the unfiltered view.
    static func rank(_ items: [HistoryItem], query: String) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { bestScore(for: $0, query: trimmed) != nil }
    }

    private static func bestScore(for item: HistoryItem, query: String) -> Int? {
        var best: Int?
        for field in [item.text, item.preview, item.sourceAppName].compactMap({ $0 }) {
            if let s = score(field, query: query) {
                best = max(best ?? Int.min, s)
            }
        }
        return best
    }

    /// All query chars appear in order, with a penalty for gaps and a bonus for
    /// adjacency. Lower band than substring matches.
    private static func subsequenceScore(_ candidate: String, _ query: String) -> Int? {
        var qi = query.startIndex
        var lastMatch: Int?
        var gapPenalty = 0
        var adjacencyBonus = 0
        for (pos, ch) in candidate.enumerated() {
            guard qi < query.endIndex else { break }
            if ch == query[qi] {
                if let last = lastMatch {
                    let gap = pos - last - 1
                    if gap == 0 { adjacencyBonus += 5 } else { gapPenalty += gap }
                }
                lastMatch = pos
                qi = query.index(after: qi)
            }
        }
        guard qi == query.endIndex else { return nil }
        return 1_000 - gapPenalty + adjacencyBonus
    }
}
