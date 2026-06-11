import Foundation
import Testing
@testable import Recallyx

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func emptyQuery_matchesEverything() {
        #expect(FuzzyMatcher.score("anything", query: "") == 0)
    }

    @Test func noMatch_returnsNil() {
        #expect(FuzzyMatcher.score("hello", query: "xyz") == nil)
    }

    @Test func caseInsensitive() {
        #expect(FuzzyMatcher.score("HELLO", query: "hello") != nil)
        #expect(FuzzyMatcher.score("hello", query: "HELLO") != nil)
    }

    @Test func ranking_exactBeatsPrefixBeatsSubstringBeatsScattered() {
        let exact = FuzzyMatcher.score("log", query: "log")!
        let prefix = FuzzyMatcher.score("logger", query: "log")!
        let substring = FuzzyMatcher.score("the log file", query: "log")!
        let scattered = FuzzyMatcher.score("lemongrass", query: "log")! // l..o..g

        #expect(exact > prefix)
        #expect(prefix > substring)
        #expect(substring > scattered)
    }

    @Test func subsequence_requiresOrder() {
        #expect(FuzzyMatcher.score("abcdef", query: "ace") != nil) // a..c..e in order
        #expect(FuzzyMatcher.score("abcdef", query: "eca") == nil) // out of order
    }

    @Test func rank_preservesInputOrder_ignoringScore() {
        // Filter-only: matches keep their recency (input) order regardless of how
        // strongly each one matched.
        let items = [
            item(text: "the log file"),     // substring
            item(text: "log"),              // exact
            item(text: "lemongrass"),       // scattered
        ]
        let ranked = FuzzyMatcher.rank(items, query: "log")
        #expect(ranked.map(\.text) == ["the log file", "log", "lemongrass"])
    }

    @Test func rank_emptyQuery_preservesOrder() {
        let items = [item(text: "a"), item(text: "b"), item(text: "c")]
        #expect(FuzzyMatcher.rank(items, query: "").map(\.text) == ["a", "b", "c"])
    }

    @Test func rank_dropsNonMatches() {
        let items = [item(text: "apple"), item(text: "banana")]
        #expect(FuzzyMatcher.rank(items, query: "apl").map(\.text) == ["apple"])
    }

    // MARK: - Bounded prefix

    @Test func boundedPrefix_shortString_returnsWhole() {
        let s = "hello"
        #expect(FuzzyMatcher.boundedPrefix(s) == s[s.startIndex...])
    }

    @Test func boundedPrefix_longString_truncatesAtLimit() {
        // Build a string larger than the default limit; verify the prefix is bounded.
        let big = String(repeating: "a", count: FuzzyMatcher.searchPrefixLimit + 100)
        let prefix = FuzzyMatcher.boundedPrefix(big)
        #expect(prefix.count <= FuzzyMatcher.searchPrefixLimit)
        #expect(prefix.count > FuzzyMatcher.searchPrefixLimit - 4) // within a char boundary
    }

    @Test func rank_matchInPrefix_syncsMatches() {
        // A match within the prefix limit is found synchronously by rank().
        let shortText = "hello world"
        let items = [item(text: shortText)]
        #expect(!FuzzyMatcher.rank(items, query: "world").isEmpty)
    }

    @Test func rank_matchBeyondPrefixLimit_notSyncMatched() {
        // A query that only matches beyond the prefix limit is NOT returned by sync rank().
        // (It would be found by the async deep-search pass instead.)
        //
        // The clip's preview must NOT contain the query either — bestScore checks all
        // three fields (text prefix, preview, sourceAppName). We use a short, neutral
        // preview so only the tail of the text body could match.
        let padding = String(repeating: "x", count: FuzzyMatcher.searchPrefixLimit)
        let tail = "uniquemarker"
        let longText = padding + tail
        let longItem = HistoryItem(
            id: UUID(), kind: .text, text: longText, imageFilename: nil,
            preview: "plain preview",     // no "uniquemarker" here
            byteSize: longText.count, sourceAppBundleID: nil, sourceAppName: nil,
            sourceAppPath: nil, createdAt: Date(), lastUsedAt: Date(),
            contentHash: tail, imageDimensions: nil
        )
        let result = FuzzyMatcher.rank([longItem], query: tail)
        #expect(result.isEmpty)
    }

    @Test func isMono_bracketOnlyInTail_notFlagged() {
        // `{` that appears only past the prefix limit should not trigger isMono.
        let padding = String(repeating: "a", count: FuzzyMatcher.searchPrefixLimit)
        let longText = padding + "{"
        var historyItem = item(text: longText)
        // preview has no code sigils either
        historyItem = HistoryItem(
            id: historyItem.id, kind: .text, text: longText, imageFilename: nil,
            preview: "plain text preview",
            byteSize: longText.count, sourceAppBundleID: nil, sourceAppName: nil,
            sourceAppPath: nil, createdAt: historyItem.createdAt,
            lastUsedAt: historyItem.lastUsedAt, contentHash: historyItem.contentHash,
            imageDimensions: nil
        )
        #expect(!historyItem.isMono)
    }

    @Test func isMono_bracketInPrefix_isFlagged() {
        let shortText = "func foo() { return 1 }"
        let historyItem = item(text: shortText)
        #expect(historyItem.isMono)
    }

    private func item(text: String) -> HistoryItem {
        HistoryItem(
            id: UUID(), kind: .text, text: text, imageFilename: nil, preview: text,
            byteSize: text.count, sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: Date(), lastUsedAt: Date(), contentHash: text, imageDimensions: nil
        )
    }
}
