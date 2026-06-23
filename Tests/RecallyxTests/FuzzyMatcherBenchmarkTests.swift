import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// A consent-safe **synthetic** benchmark for the fuzzy scorer. No real user clip
/// content is read here — every clip below is invented to be representative of the
/// short-query pain: short clips (commands, URLs, tokens, passwords, names, file
/// names) mixed with long clips (a bash script, a JSON blob, a log dump, prose)
/// chosen so that short-query characters appear *scattered* in the long clips.
///
/// The metric ranks the whole corpus by `FuzzyMatcher.score` for each query and
/// checks where the labelled "intended" clip lands. We report top-1 / top-3 hit
/// rate and mean rank so the scorer can be compared before/after.
@Suite("FuzzyMatcher benchmark")
struct FuzzyMatcherBenchmarkTests {

    // MARK: Synthetic corpus (id-tagged so queries can name an intended target)

    struct Clip { let id: String; let text: String }

    static let corpus: [Clip] = [
        // --- short clips ---
        Clip(id: "cmd-image-build", text: "docker build -t myapp:latest ."),
        Clip(id: "url-images", text: "https://example.com/images/hero.png"),
        Clip(id: "url-login", text: "https://accounts.example.com/login?next=/dashboard"),
        Clip(id: "api-token", text: "sk-proj-AbCd1234TOKEN5678efgh"),
        Clip(id: "bearer-key", text: "Authorization: Bearer eyKEY9f8a7b6c5d4e"),
        Clip(id: "password", text: "Tr0ub4dor&3-passw0rd"),
        Clip(id: "filename-image", text: "image.png"),
        Clip(id: "filename-config", text: "config.yaml"),
        Clip(id: "person-name", text: "Jane Doe"),
        Clip(id: "person-name2", text: "Robert Smith"),
        Clip(id: "git-cmd", text: "git checkout -b feature/search"),
        Clip(id: "ssh-cmd", text: "ssh deploy@prod.example.com"),
        Clip(id: "ip-addr", text: "192.168.1.42"),
        Clip(id: "email", text: "support@example.com"),
        Clip(id: "short-key-word", text: "key"),
        Clip(id: "short-url-word", text: "url"),
        Clip(id: "short-image-word", text: "image"),
        Clip(id: "uuid", text: "550e8400-e29b-41d4-a716-446655440000"),
        Clip(id: "brew-cmd", text: "brew install ripgrep"),
        Clip(id: "npm-cmd", text: "npm run build && npm test"),
        Clip(id: "color-hex", text: "#1a2b3c"),
        Clip(id: "phone", text: "+1 (415) 555-0199"),

        // --- long clips (chosen so short-query chars appear scattered) ---
        Clip(id: "bash-script", text: """
        #!/usr/bin/env bash
        set -euo pipefail
        # build and manage a great image pipeline
        for f in *.png; do
          echo "processing $f"
          magick "$f" -resize 50% "out/$f"
          gzip --keep "out/$f"
        done
        echo "all images generated"
        rsync -avz out/ deploy@prod.example.com:/var/www/images/
        """),
        Clip(id: "json-blob", text: """
        {
          "imageMetadata": { "format": "png", "managed": true },
          "user": { "key": "main-account", "url": "https://api.example.com/v2" },
          "tokens": ["alpha", "gamma", "theta"],
          "logEntries": [{ "level": "info", "msg": "garbage collected" }],
          "settings": { "uglify": true, "lazyrender": false }
        }
        """),
        Clip(id: "log-dump", text: """
        2026-06-23 10:01:14 INFO  starting image-resize-worker
        2026-06-23 10:01:15 DEBUG loaded key material from keyring
        2026-06-23 10:01:16 WARN  url malformed, retrying upstream
        2026-06-23 10:01:17 ERROR garbage in manifest, ignoring
        2026-06-23 10:01:18 INFO  uploaded generated images successfully
        2026-06-23 10:01:19 DEBUG token refreshed for gateway
        """),
        Clip(id: "prose", text: """
        I am genuinely glad we managed to get everyone aligned. The marketing engine
        keeps urging us to ship, and the user research really underlines how key the
        onboarding flow is. Let us regroup tomorrow and keep the momentum going.
        """),
        Clip(id: "css-block", text: """
        .image-grid { display: grid; gap: 1rem; }
        .image-grid img { border-radius: 8px; object-fit: cover; }
        .url-pill { padding: 4px 8px; background: #eee; }
        .key-row { font-weight: 600; }
        """),
        Clip(id: "sql-dump", text: """
        SELECT u.id, u.email, k.api_key, img.url
        FROM users u
        JOIN keys k ON k.user_id = u.id
        LEFT JOIN images img ON img.owner = u.id
        WHERE u.created_at > '2026-01-01' ORDER BY u.id;
        """),
        Clip(id: "markdown-doc", text: """
        # Image guidelines
        Use a managed key for uploads. Each generated url must be unique.
        See https://docs.example.com/images for the full guide. Avoid garbage tokens.
        """),
        Clip(id: "yaml-config", text: """
        image: registry.example.com/app:latest
        replicas: 3
        env:
          - name: API_KEY
            valueFrom: { secretKeyRef: { name: app-secrets, key: token } }
          - name: BASE_URL
            value: https://gateway.example.com
        """),
    ]

    /// (query, intended-clip-id). The intended clip is the short clip a user typing
    /// this short query most plausibly wants — the long clips are the scattered
    /// false positives we want pushed down.
    static let cases: [(query: String, intended: String)] = [
        ("image", "filename-image"),
        ("images", "url-images"),
        ("url", "short-url-word"),
        ("key", "short-key-word"),
        ("token", "api-token"),
        ("bearer", "bearer-key"),
        ("passw", "password"),
        ("login", "url-login"),
        ("config", "filename-config"),
        ("jane", "person-name"),
        ("docker", "cmd-image-build"),
        ("brew", "brew-cmd"),
        ("ripgrep", "brew-cmd"),
        ("ssh", "ssh-cmd"),
    ]

    /// Rank the whole corpus for a query by `score`, descending. Ties broken by the
    /// corpus order (stable) — mirrors how a score-sorted result list would read.
    static func ranking(for query: String) -> [(id: String, score: Int)] {
        corpus
            .compactMap { clip -> (String, Int)? in
                guard let s = FuzzyMatcher.score(clip.text, query: query) else { return nil }
                return (clip.id, s)
            }
            .enumerated()
            .sorted { a, b in
                if a.element.1 != b.element.1 { return a.element.1 > b.element.1 }
                return a.offset < b.offset  // stable
            }
            .map { ($0.element.0, $0.element.1) }
    }

    /// Rank of the intended clip (1-based), or nil if it didn't match at all.
    static func rankOfIntended(query: String, intended: String) -> Int? {
        let order = ranking(for: query).map(\.id)
        guard let idx = order.firstIndex(of: intended) else { return nil }
        return idx + 1
    }

    /// The long clips — the ones whose scattered subsequence hits are the *noise*
    /// we want to suppress. A short query that matches one of these via a sparse
    /// subsequence (no contiguous run) is a false positive polluting the list.
    static let longClipIDs: Set<String> = [
        "bash-script", "json-blob", "log-dump", "prose", "css-block",
        "sql-dump", "markdown-doc", "yaml-config",
    ]

    /// Count of long clips that `rank` (the real filter the panel uses) *includes*
    /// for a query — these surface in the list (in recency order) and pollute it.
    static func longClipNoise(query: String) -> Int {
        let items = corpus.map { c in
            HistoryItem(
                id: UUID(), kind: .text, text: c.text, imageFilename: nil, preview: c.text,
                byteSize: c.text.count, sourceAppBundleID: nil, sourceAppName: nil,
                sourceAppPath: nil, createdAt: Date(), lastUsedAt: Date(),
                contentHash: c.id, imageDimensions: nil
            )
        }
        // Map back kept items to ids via contentHash, count long ones.
        let kept = FuzzyMatcher.rank(items, query: query)
        return kept.filter { longClipIDs.contains($0.contentHash) }.count
    }

    struct Metrics { var top1: Int; var top3: Int; var meanRank: Double; var total: Int }

    static func computeMetrics() -> Metrics {
        var top1 = 0, top3 = 0, rankSum = 0
        for c in cases {
            guard let r = rankOfIntended(query: c.query, intended: c.intended) else {
                rankSum += corpus.count + 1  // unmatched ⇒ worst possible
                continue
            }
            if r == 1 { top1 += 1 }
            if r <= 3 { top3 += 1 }
            rankSum += r
        }
        return Metrics(
            top1: top1, top3: top3,
            meanRank: Double(rankSum) / Double(cases.count),
            total: cases.count
        )
    }

    /// Prints the per-case ranking + aggregate metrics. Always passes — it's a
    /// reporting harness; the threshold assertions live in the dedicated tests
    /// below so this stays a pure measurement.
    @Test func report() {
        var lines: [String] = []
        lines.append("query            intended-rank  top@3?  intended-id")
        for c in Self.cases {
            let r = Self.rankOfIntended(query: c.query, intended: c.intended)
            let rankStr = r.map(String.init) ?? "MISS"
            let top3 = (r.map { $0 <= 3 } ?? false) ? "yes" : "NO"
            lines.append(String(format: "%-16@ %-14@ %-7@ %@",
                                c.query as NSString, rankStr as NSString,
                                top3 as NSString, c.intended as NSString))
        }
        let m = Self.computeMetrics()
        var totalNoise = 0
        lines.append("")
        lines.append("query            long-clip-noise (false positives in filtered list)")
        for c in Self.cases {
            let n = Self.longClipNoise(query: c.query)
            totalNoise += n
            lines.append(String(format: "%-16@ %d", c.query as NSString, n))
        }
        lines.append("")
        lines.append(String(format: "top-1 hit:  %d/%d", m.top1, m.total))
        lines.append(String(format: "top-3 hit:  %d/%d", m.top3, m.total))
        lines.append(String(format: "mean rank:  %.2f", m.meanRank))
        lines.append(String(format: "total long-clip noise: %d", totalNoise))
        print("\n=== FuzzyMatcher short-query benchmark ===\n" + lines.joined(separator: "\n") + "\n")
        #expect(m.total == Self.cases.count)
    }

    /// Quality gate: the intended short clip is reliably top-ranked, and the
    /// scattered-subsequence noise in the filtered list stays well below the
    /// pre-change baseline (84). These pin the win so a future scorer tweak can't
    /// silently regress short-query search.
    @Test func intendedMatch_isTopRanked() {
        for c in Self.cases {
            let r = Self.rankOfIntended(query: c.query, intended: c.intended)
            #expect(r != nil, "query '\(c.query)' lost its intended match '\(c.intended)'")
            #expect((r ?? 99) <= 3, "query '\(c.query)' intended match ranked \(r ?? 99) (> 3)")
        }
        let m = Self.computeMetrics()
        #expect(m.top1 >= 13)
        #expect(m.top3 == m.total)
        #expect(m.meanRank <= 1.2)
    }

    @Test func scatteredNoise_staysWellBelowBaseline() {
        let totalNoise = Self.cases.reduce(0) { $0 + Self.longClipNoise(query: $1.query) }
        // Baseline (pure subsequence, no span gate) was 84 across these cases.
        // The span gate must keep total long-clip inclusions comfortably under half.
        #expect(totalNoise <= 40, "long-clip noise regressed to \(totalNoise) (baseline was 84)")
    }
}
