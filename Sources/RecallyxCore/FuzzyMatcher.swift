import Foundation

/// Subsequence fuzzy matching with ranking. A query matches a candidate when its
/// characters appear in order (case-insensitive). Ranking, best first:
/// exact > prefix > contiguous substring > scattered subsequence. Returns `nil`
/// when there's no match at all.
public enum FuzzyMatcher {
    /// Maximum bytes of `HistoryItem.text` scanned during a synchronous search pass.
    /// Items with text longer than this are still matched — via a bounded prefix
    /// here, and full-text async in `HistoryPanelViewModel.refreshClips` — so no
    /// match is ever permanently dropped; this bound only controls how much is
    /// scanned on the main thread per keystroke.
    public static let searchPrefixLimit = 16 * 1024  // 16 KB

    public static func score(_ candidate: String, query: String) -> Int? {
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
    ///
    /// Text is matched against a bounded prefix (`searchPrefixLimit` bytes) to
    /// keep main-thread cost O(1) per item regardless of clip size. Items where
    /// only the tail (beyond the prefix) matches are surfaced by the async
    /// deep-search pass in `HistoryPanelViewModel`.
    public static func rank(_ items: [HistoryItem], query: String) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { bestScore(for: $0, query: trimmed) != nil }
    }

    private static func bestScore(for item: HistoryItem, query: String) -> Int? {
        var best: Int?
        // preview and sourceAppName are already short; text is bounded to prefix.
        var candidates: [String] = [item.preview]
        if let text = item.text { candidates.append(String(boundedPrefix(text))) }
        if let name = item.sourceAppName { candidates.append(name) }
        for field in candidates {
            if let s = score(field, query: query) {
                best = max(best ?? Int.min, s)
            }
        }
        return best
    }

    /// Returns a view into `s` truncated to at most `searchPrefixLimit` UTF-8
    /// bytes while preserving valid `Character` boundaries.
    public static func boundedPrefix(_ s: String) -> Substring {
        guard s.utf8.count > searchPrefixLimit else { return s[...] }
        var byteIdx = s.utf8.index(s.utf8.startIndex, offsetBy: searchPrefixLimit)
        // Walk back within the UTF-8 view until we land on a character boundary
        // (at most 3 bytes for a 4-byte grapheme cluster).
        while byteIdx > s.utf8.startIndex, byteIdx.samePosition(in: s) == nil {
            byteIdx = s.utf8.index(before: byteIdx)
        }
        let charIdx = byteIdx.samePosition(in: s) ?? s.startIndex
        return s[s.startIndex..<charIdx]
    }

    /// All query chars appear in order, with a penalty for gaps and a bonus for
    /// adjacency. Lower band than substring matches.
    ///
    /// A subsequence match is only meaningful when the matched characters sit
    /// reasonably close together. Without this, a short query (`image`, `url`,
    /// `key`) "matches" almost any long clip (script/JSON/log) because its few
    /// characters appear *scattered* across thousands of bytes — flooding the
    /// filtered list with noise. We therefore reject matches whose **span**
    /// (distance from the first to the last matched character) is far larger than
    /// the query — the match has to be dense, not spread across the whole clip.
    private static func subsequenceScore(_ candidate: String, _ query: String) -> Int? {
        let qCount = query.count
        var qi = query.startIndex
        var firstMatch: Int?
        var lastMatch: Int?
        var gapPenalty = 0
        var adjacencyBonus = 0
        // Longest contiguous matched run: consecutive candidate positions that matched
        // consecutive query chars. `currentRun` grows on an adjacent match (gap == 0)
        // and resets to 1 on any gap; `longestRun` keeps the best seen.
        var currentRun = 0
        var longestRun = 0
        for (pos, ch) in candidate.enumerated() {
            guard qi < query.endIndex else { break }
            if ch == query[qi] {
                if let last = lastMatch {
                    let gap = pos - last - 1
                    if gap == 0 { adjacencyBonus += 5; currentRun += 1 }
                    else { gapPenalty += gap; currentRun = 1 }
                } else {
                    currentRun = 1
                }
                longestRun = max(longestRun, currentRun)
                if firstMatch == nil { firstMatch = pos }
                lastMatch = pos
                qi = query.index(after: qi)
            }
        }
        guard qi == query.endIndex, let first = firstMatch, let last = lastMatch
        else { return nil }

        // Span density gate: keep only matches packed within a bounded window.
        // The window scales with the query so longer queries get more slack, but a
        // few characters can never legitimately span a whole document. Short queries
        // (≤3 chars) get a tight clamp — a handful of chars must not roam a whole line
        // — while longer queries keep the original scaling exactly.
        let span = last - first + 1
        let maxSpan: Int
        if qCount <= 3 {
            maxSpan = qCount + shortQuerySpanSlack
        } else {
            maxSpan = max(qCount * sparseSpanFactor, qCount + sparseSpanFloor)
        }
        guard span <= maxSpan else { return nil }

        // Contiguous-run gate: an all-singleton scatter (every matched char isolated)
        // is the noise signature, so require roughly half the query to land as one
        // contiguous run. Only applied to queries of 4+ chars, where "half the query
        // as a run" is a meaningful signal: for 1–3 char queries a fully-scattered
        // subsequence is still legitimate recall (e.g. "log" in "lemongrass", "cfg"
        // in "config") and the short-query span clamp above already suppresses their
        // noise — applying the run gate there would drop genuine hits.
        if qCount >= contiguousRunGateMinQuery, longestRun < max(2, (qCount + 1) / 2) {
            return nil
        }

        // Length-normalize within the subsequence band: a tighter span (less
        // padding between the query's own characters) ranks higher.
        let slack = span - qCount  // extra chars threaded between matches
        return 1_000 - gapPenalty - slack + adjacencyBonus
    }

    /// Span-gate tuning: a subsequence match is kept only when its span is within
    /// `max(qCount * factor, qCount + floor)` characters. Tight enough to drop
    /// chars-scattered-across-a-script noise, loose enough to keep genuine
    /// near-contiguous fuzzy hits (e.g. "log" in "lemongrass").
    private static let sparseSpanFactor = 4
    private static let sparseSpanFloor = 12

    /// Short-query span clamp: for queries of ≤3 chars the window is `qCount + this`,
    /// far tighter than the general floor (`+sparseSpanFloor`), so a 2–3 char query
    /// can't legitimately match chars scattered across a whole line of a script/JSON.
    private static let shortQuerySpanSlack = 4

    /// The contiguous-run gate only applies from this query length up. Below it a
    /// fully-scattered subsequence is still legitimate recall for short queries, and
    /// the short-query span clamp already handles their noise.
    private static let contiguousRunGateMinQuery = 4
}
