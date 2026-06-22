import Foundation
import Testing
@testable import Recallyx

@MainActor
@Suite("UsageJournal")
struct UsageJournalTests {

    /// A fixed instant so output is deterministic (no wall clock).
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Fresh journal rooted at a unique temp file, plus its URL.
    private func makeJournal(enabled: Bool) -> (UsageJournal, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-journal-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage.jsonl")
        let journal = UsageJournal(enabled: enabled, fileURL: url, now: { self.fixedDate })
        return (journal, url)
    }

    /// Read the file as a string (nil if it doesn't exist).
    private func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Non-empty lines of the file.
    private func lines(_ url: URL) -> [String] {
        (contents(url) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Await the journal's pending off-main write so assertions are deterministic.
    private func flush(_ journal: UsageJournal) async {
        await journal.lastWrite?.value
    }

    @Test func disabled_writesNothing() async {
        let (journal, url) = makeJournal(enabled: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        journal.log("panel_open", ["mode": "history"])
        await flush(journal)

        // No task was even created; the file must be absent.
        #expect(journal.lastWrite == nil)
        #expect(contents(url) == nil)
    }

    @Test func enabled_appendsExactlyOneValidJSONLine() async throws {
        let (journal, url) = makeJournal(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        journal.log("panel_open", ["mode": "history"])
        await flush(journal)

        let all = lines(url)
        #expect(all.count == 1)

        let obj = try JSONSerialization.jsonObject(with: Data(all[0].utf8)) as? [String: Any]
        #expect(obj?["event"] as? String == "panel_open")
        #expect(obj?["mode"] as? String == "history")
        // `ts` is the injected fixed instant, formatted ISO8601 — present + non-empty.
        #expect((obj?["ts"] as? String)?.isEmpty == false)
    }

    @Test func neverWritesProvidedClipText() async {
        let (journal, url) = makeJournal(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let secret = "SUPER-SECRET-CLIPBOARD-CONTENTS-12345"
        // A correct caller logs only the LENGTH, never the text. Even so, the
        // secret string must never appear anywhere in the output.
        journal.log("search", ["queryLength": secret.count, "resultCount": 3])
        await flush(journal)

        let text = contents(url) ?? ""
        #expect(!text.contains(secret))
    }

    @Test func searchStoresQueryLengthNotTheText() async throws {
        let (journal, url) = makeJournal(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let query = "hello world"
        journal.log("search", ["queryLength": query.count, "resultCount": 7])
        await flush(journal)

        let obj = try JSONSerialization.jsonObject(with: Data(lines(url)[0].utf8)) as? [String: Any]
        #expect(obj?["queryLength"] as? Int == query.count)
        #expect(obj?["resultCount"] as? Int == 7)
        // The query text itself is absent.
        #expect(!(contents(url) ?? "").contains(query))
    }

    @Test func sizeCap_keepsNewestWithinBound() async {
        let (journal, url) = makeJournal(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Each event carries a ~4 KB filler plus a monotonically increasing seq,
        // so we both blow past the 2 MB cap and can identify the newest survivors.
        let filler = String(repeating: "x", count: 4096)
        let total = 700  // 700 × ~4 KB ≈ 2.8 MB written → must trim under 2 MB
        for seq in 0..<total {
            journal.log("paste", ["seq": seq, "pad": filler])
            await flush(journal)
        }

        // File stays within the hard cap.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        #expect(size <= UsageJournal.maxBytes)

        // The newest event survived; the very oldest was dropped.
        let all = lines(url)
        #expect(!all.isEmpty)
        let seqs: [Int] = all.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["seq"] as? Int
        }
        #expect(seqs.last == total - 1)   // newest kept
        #expect(seqs.first ?? 0 > 0)       // oldest dropped
    }

    @Test func everyLineIsOneJSONObject() async throws {
        let (journal, url) = makeJournal(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        journal.log("panel_open", ["mode": "history"])
        await flush(journal)
        journal.log("search", ["queryLength": 5, "resultCount": 2])
        await flush(journal)
        journal.log("paste", ["via": "return", "clipKind": "text"])
        await flush(journal)
        journal.log("action_run", [
            "name": "Fix grammar (EN)", "kind": "AI",
            "stepTypes": ["ai"], "provider": "openai", "clipKind": "text", "custom": false,
        ])
        await flush(journal)
        journal.log("action_error", ["name": "Custom", "category": "missingApiKey"])
        await flush(journal)
        journal.log("transform_selection", ["captured": true])
        await flush(journal)

        let all = lines(url)
        #expect(all.count == 6)
        for line in all {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
            #expect(obj is [String: Any])
            #expect(!line.contains("\n"))
        }
    }

    @Test func clear_removesTheFile() async {
        let (journal, url) = makeJournal(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        journal.log("panel_open", ["mode": "history"])
        await flush(journal)
        #expect(contents(url) != nil)

        journal.clear()
        #expect(contents(url) == nil)
    }
}
