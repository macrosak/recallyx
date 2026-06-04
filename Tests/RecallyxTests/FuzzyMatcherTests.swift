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

    @Test func rank_ordersItemsByScore() {
        let items = [
            item(text: "the log file"),     // substring
            item(text: "log"),              // exact
            item(text: "lemongrass"),       // scattered
        ]
        let ranked = FuzzyMatcher.rank(items, query: "log")
        #expect(ranked.map(\.text) == ["log", "the log file", "lemongrass"])
    }

    @Test func rank_emptyQuery_preservesOrder() {
        let items = [item(text: "a"), item(text: "b"), item(text: "c")]
        #expect(FuzzyMatcher.rank(items, query: "").map(\.text) == ["a", "b", "c"])
    }

    @Test func rank_dropsNonMatches() {
        let items = [item(text: "apple"), item(text: "banana")]
        #expect(FuzzyMatcher.rank(items, query: "apl").map(\.text) == ["apple"])
    }

    private func item(text: String) -> HistoryItem {
        HistoryItem(
            id: UUID(), kind: .text, text: text, imageFilename: nil, preview: text,
            byteSize: text.count, sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: Date(), lastUsedAt: Date(), contentHash: text, imageDimensions: nil
        )
    }
}
