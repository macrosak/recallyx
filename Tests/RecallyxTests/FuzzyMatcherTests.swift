import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

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

    // MARK: - Sparse-span gate (short-query noise suppression)

    @Test func sparseSubsequence_acrossLongClip_isRejected() {
        // "image" with its characters scattered across a long script must NOT match:
        // the chars appear in order but spread over thousands of bytes.
        let script = """
        #!/usr/bin/env bash
        for f in *.png; do
          echo "processing $f"
          \(String(repeating: "x", count: 2000))
          gzip --keep "$f"
        done
        echo "everything done"
        """
        // No literal "image" substring; the i/m/a/g/e only appear far apart.
        #expect(!script.lowercased().contains("image"))
        #expect(FuzzyMatcher.score(script, query: "image") == nil)
    }

    @Test func nearContiguousSubsequence_isStillKept() {
        // The classic loose-but-tight fuzzy hit survives the span gate.
        #expect(FuzzyMatcher.score("lemongrass", query: "log") != nil) // l..o..g, span 6
    }

    @Test func contiguousSubstring_neverGatedOut() {
        // A real substring match is in a higher band than subsequence — the sparse
        // gate must never touch it, even inside a long document.
        let doc = String(repeating: "z", count: 5000) + " imageMetadata " + String(repeating: "z", count: 5000)
        #expect(FuzzyMatcher.score(doc, query: "image") != nil)
    }

    @Test func tighterSubsequence_outranksLooserOne() {
        // Length-normalized subsequence band: less slack between matched chars ranks higher.
        let tight = FuzzyMatcher.score("a_b_c", query: "abc")!   // span 5, slack 2
        let loose = FuzzyMatcher.score("a__b__c", query: "abc")! // span 7, slack 4
        #expect(tight > loose)
    }

    @Test func rank_shortQuery_dropsScatteredLongClip_keepsIntendedShort() {
        // Typing "url" should keep the short clip and drop a long script where u/r/l
        // only appear scattered.
        let intended = item(text: "url")
        let scattered = item(text: """
        function update() {
          \(String(repeating: "q", count: 1500))
          return result.value;
        }
        """)
        // sanity: no literal "url" substring in the scattered clip
        #expect(!scattered.text!.lowercased().contains("url"))
        let kept = FuzzyMatcher.rank([scattered, intended], query: "url")
        #expect(kept.map(\.text) == ["url"])
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

    // MARK: - Tightened short-query scoring (contiguous-run gate + short-query span clamp)

    @Test func shortQuery_url_scatteredAcrossDeployScript_isRejected() {
        // "url" typed at a deploy/grep script: u/r/l appear in order but spread far
        // apart, so the tightened short-query span clamp drops it.
        let script = """
        git checkout -b feature/parser
        npm run build && npm run lint
        """
        #expect(!script.lowercased().contains("url"))
        #expect(FuzzyMatcher.score(script, query: "url") == nil)
    }

    @Test func shortQuery_key_scatteredAcrossBundleID_isRejected() {
        // "key" against a bundle id: k…e…y are scattered (span 9), past the clamp.
        let bundleID = "io.github.macrosak.recallyx"
        #expect(!bundleID.lowercased().contains("key"))
        #expect(FuzzyMatcher.score(bundleID, query: "key") == nil)
    }

    @Test func twoCharQuery_scatteredAcrossLongClip_isRejected() {
        // 2-char queries are the worst offenders — their handful of chars land in
        // almost any clip. Both "ls" and "vi" appear in-order but scattered here.
        let clip = "SELECT value FROM inventory WHERE stock > 0 ORDER BY id;"
        #expect(!clip.lowercased().contains("ls"))
        #expect(!clip.lowercased().contains("vi"))
        #expect(FuzzyMatcher.score(clip, query: "ls") == nil)
        #expect(FuzzyMatcher.score(clip, query: "vi") == nil)
    }

    @Test func fourCharQuery_allSingletonScatter_rejectedByRunGate() {
        // A 4-char query whose chars are each isolated is within the span gate's
        // window (span 7 ≤ the qCount≥4 window) yet has no contiguous run — exactly
        // what the contiguous-run gate exists to drop.
        #expect(FuzzyMatcher.score("g_r_e_p", query: "grep") == nil)
    }

    @Test func exactPrefixSubstringBands_untouchedByGates() {
        // The high bands never route through subsequenceScore, so no gate can touch
        // them — even for short queries.
        #expect(FuzzyMatcher.score("url", query: "url") != nil)          // exact
        #expect(FuzzyMatcher.score("urls.txt", query: "url") != nil)     // prefix
        #expect(FuzzyMatcher.score("the url here", query: "url") != nil) // substring
    }

    @Test func nearContiguousSubsequence_cfgInConfig_isKept() {
        // "cfg" in "config" — c..f..g, span 6 — is a genuine near-contiguous fuzzy
        // hit and must survive both gates (the run gate is inactive for ≤3 chars).
        #expect(!"config".contains("cfg"))
        #expect(FuzzyMatcher.score("config", query: "cfg") != nil)
    }

    @Test func denseSubsequence_withContiguousRun_isKept() {
        // A dense hit whose matched chars form a real run passes the run gate: "abcd"
        // in "abXcd" lands as "ab" + "cd" (longest run 2 ≥ the qCount-4 threshold).
        #expect(!"abxcd".contains("abcd"))
        #expect(FuzzyMatcher.score("abXcd", query: "abcd") != nil)
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
        // Limit is in bytes; ASCII chars are 1 byte each so count == utf8.count here.
        #expect(prefix.utf8.count <= FuzzyMatcher.searchPrefixLimit)
        #expect(prefix.utf8.count > FuzzyMatcher.searchPrefixLimit - 4)
    }

    @Test func boundedPrefix_multibyteAtBoundary_staysBounded() {
        // Emoji are 4 UTF-8 bytes; force the 16 KB limit to land mid-emoji.
        let head = String(repeating: "a", count: FuzzyMatcher.searchPrefixLimit - 2)
        let big = head + "😀😀😀😀"  // boundary at -2 bytes splits the first emoji
        let prefix = FuzzyMatcher.boundedPrefix(big)
        #expect(prefix.utf8.count <= FuzzyMatcher.searchPrefixLimit)
        // Must not hand back the whole string (the pre-fix bug returned s.endIndex - 1).
        #expect(prefix.utf8.count < big.utf8.count - 4)
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
