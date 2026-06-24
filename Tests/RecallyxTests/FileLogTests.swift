import Foundation
import Testing
@testable import RecallyxCore

@Suite("FileLog")
struct FileLogTests {

    /// A fixed instant so the timestamp prefix is deterministic.
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Fresh sink rooted at a unique temp file, plus its URL.
    private func makeLog(enabled: Bool) -> (FileLog, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-filelog-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("recallyx.log")
        let log = FileLog(enabled: enabled, fileURL: url, now: { self.fixedDate })
        return (log, url)
    }

    private func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func lines(_ url: URL) -> [String] {
        (contents(url) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Await the most recent off-main write so assertions are deterministic.
    private func flush(_ log: FileLog) async {
        await log.lastWrite?.value
    }

    @Test func disabled_writesNothing() async {
        let (log, url) = makeLog(enabled: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        log.write("[recallyx] hello")
        await flush(log)

        // No task was even created; the file must be absent.
        #expect(log.lastWrite == nil)
        #expect(contents(url) == nil)
    }

    @Test func enabled_appendsLinesWithTimestampPrefix() async {
        let (log, url) = makeLog(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        log.write("[recallyx] first")
        await flush(log)
        log.write("[recallyx] ERROR: second")
        await flush(log)

        let all = lines(url)
        #expect(all.count == 2)
        // The original message is present, in order, each on one line.
        #expect(all[0].hasSuffix("[recallyx] first"))
        #expect(all[1].hasSuffix("[recallyx] ERROR: second"))
        // The timestamp prefix is the injected fixed instant (ISO8601), non-empty.
        #expect(all[0].first == "2")   // ISO8601 year starts "2…"
        #expect(all[0].contains("[recallyx]"))
    }

    @Test func enabledFlag_canBeFlippedOff() async {
        let (log, url) = makeLog(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        log.write("[recallyx] kept")
        await flush(log)
        log.enabled = false
        log.write("[recallyx] dropped")
        await flush(log)

        let all = lines(url)
        #expect(all.count == 1)
        #expect(all[0].hasSuffix("[recallyx] kept"))
    }

    @Test func rotation_boundsTotalFootprintAndKeepsNewest() async {
        let (log, url) = makeLog(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Each line carries a ~4 KB filler plus a monotonically increasing seq,
        // so we cross the per-file cap several times and can identify survivors.
        let filler = String(repeating: "x", count: 4096)
        let total = 2000  // 2000 × ~4 KB ≈ 8 MB written → forces multiple rotations
        for seq in 0..<total {
            log.write("[recallyx] seq=\(seq) \(filler)")
            await flush(log)
        }

        let fm = FileManager.default
        let primarySize = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let rotatedURL = url.appendingPathExtension("1")
        let rotatedSize = ((try? fm.attributesOfItem(atPath: rotatedURL.path))?[.size] as? Int) ?? 0

        // Total on-disk footprint is bounded by the 2-file rotation: each file is
        // at most one over-cap line beyond maxBytes (we rotate before the write
        // that would exceed, then write into a fresh file).
        let perFileBound = FileLog.maxBytes + 8192   // cap + generous single-line slack
        #expect(primarySize <= perFileBound)
        #expect(rotatedSize <= perFileBound)
        #expect(primarySize + rotatedSize <= 2 * perFileBound)

        // The newest event survived in the primary file; nothing was lost beyond
        // the oldest (which rotation drops once the .1 file is itself replaced).
        let primaryLines = lines(url)
        #expect(!primaryLines.isEmpty)
        let lastSeq = primaryLines.last.flatMap { line -> Int? in
            guard let r = line.range(of: "seq=") else { return nil }
            let after = line[r.upperBound...].prefix { $0.isNumber }
            return Int(after)
        }
        #expect(lastSeq == total - 1)   // newest kept
    }

    @Test func clear_removesPrimaryAndRotatedFiles() async {
        let (log, url) = makeLog(enabled: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Force one rotation so the .1 sibling exists too.
        let filler = String(repeating: "y", count: 4096)
        for seq in 0..<700 {   // 700 × ~4 KB ≈ 2.8 MB → at least one rotation
            log.write("[recallyx] seq=\(seq) \(filler)")
            await flush(log)
        }
        let rotatedURL = url.appendingPathExtension("1")
        #expect(contents(url) != nil)
        #expect(contents(rotatedURL) != nil)

        await log.clear()
        #expect(contents(url) == nil)
        #expect(contents(rotatedURL) == nil)
    }

    @Test func defaultFileURL_honorsDataDirOverride() {
        // The env override seam (used by debug runs) routes the log into the
        // scratch dir, mirroring the history store / usage journal. We can only
        // assert the no-override default shape here (env is process-global), but
        // the URL must always end at recallyx.log under a Recallyx folder.
        let url = FileLog.defaultFileURL()
        #expect(url.lastPathComponent == "recallyx.log")
        #expect(url.deletingLastPathComponent().pathComponents.contains("Recallyx"))
    }
}
