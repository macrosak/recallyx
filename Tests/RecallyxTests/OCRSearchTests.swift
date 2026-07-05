import CoreData
import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// OCR-powered image search: the pure/storage parts (no real Vision call — the
/// recognizer is injected). Covers the `ocrText` round-trip + dirty-set persist,
/// the "" sentinel, `FuzzyMatcher` ranking image clips by OCR text, backfill
/// candidate selection, and the OCR service's capture + backfill orchestration.
@MainActor
@Suite("OCR image search")
struct OCRSearchTests {

    // MARK: - Helpers

    private func makeStore(cap: Int = 1000) -> (HistoryStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-ocr-tests-\(UUID().uuidString)", isDirectory: true)
        return (HistoryStore(baseURL: base, cap: cap), base)
    }

    private func imageClip(_ bytes: [UInt8], dims: String = "10 × 10") -> CapturedClip {
        let data = Data(bytes)
        return CapturedClip(
            kind: .image, text: nil, imageData: data, preview: "Image · \(dims)",
            byteSize: data.count, sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            contentHash: ContentHash.of(bytes: data), imageDimensions: dims
        )
    }

    private func imageItem(id: UUID = UUID(), ocrText: String?) -> HistoryItem {
        let now = Date()
        return HistoryItem(
            id: id, kind: .image, text: nil, imageFilename: "\(id).png",
            preview: "Image · 10 × 10", byteSize: 4, createdAt: now, lastUsedAt: now,
            contentHash: UUID().uuidString, imageDimensions: "10 × 10", ocrText: ocrText
        )
    }

    private func textItem(_ s: String) -> HistoryItem {
        let now = Date()
        return HistoryItem(
            id: UUID(), kind: .text, text: s, preview: s, byteSize: s.utf8.count,
            createdAt: now, lastUsedAt: now, contentHash: ContentHash.of(text: s)
        )
    }

    // MARK: - Store round-trip + persist

    @Test func setOCRText_setsAndPersists() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(imageClip([1, 2, 3, 4]))
        #expect(store.items.first?.ocrText == nil)   // fresh clip: never OCRed

        store.setOCRText(id: id, text: "  Hello World  ")
        #expect(store.items.first?.ocrText == "Hello World")   // trimmed
        store.flush()

        let reloaded = HistoryStore(baseURL: base)
        #expect(reloaded.items.first?.ocrText == "Hello World")
    }

    @Test func setOCRText_emptyResultStoresSentinelNotNil() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(imageClip([1, 2, 3, 4]))
        store.setOCRText(id: id, text: "   \n  ")   // whitespace-only OCR result
        // "" sentinel: distinguishes OCRed-empty from never-OCRed (nil).
        #expect(store.items.first?.ocrText == "")
    }

    @Test func setOCRText_unchangedValueDoesNotChurnDirtySet() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(imageClip([1, 2, 3, 4]))
        store.setOCRText(id: id, text: "abc")
        store.flush()

        var notified = false
        store.onChange = { notified = true }
        store.setOCRText(id: id, text: "abc")   // same value
        #expect(!notified)   // no-op: no mutation, no onChange
    }

    @Test func setOCRText_unknownIDIsNoOp() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(imageClip([1, 2, 3, 4]))
        store.setOCRText(id: UUID(), text: "ghost")   // id not in the store
        #expect(store.items.allSatisfy { $0.ocrText == nil })
    }

    // MARK: - Backfill candidate selection

    @Test func backfillCandidates_onlyNeverOCRedImagesWithLocalPNG() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let neverID = store.add(imageClip([1, 1, 1, 1]))          // ocrText nil → candidate
        let emptyID = store.add(imageClip([2, 2, 2, 2]))
        store.setOCRText(id: emptyID, text: "")                    // OCRed-empty → NOT a candidate
        let doneID = store.add(imageClip([3, 3, 3, 3]))
        store.setOCRText(id: doneID, text: "already read")         // has text → NOT a candidate

        let candidates = store.ocrBackfillCandidates()
        #expect(candidates.map(\.id) == [neverID])
    }

    @Test func backfillCandidates_excludeMissingPNG() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(imageClip([4, 4, 4, 4]))
        // Delete the backing PNG behind the store's back.
        if let url = store.items.first.flatMap({ store.imageURL(for: $0) }) {
            try? FileManager.default.removeItem(at: url)
        }
        _ = id
        #expect(store.ocrBackfillCandidates().isEmpty)
    }

    @Test func backfillCandidates_excludeTextClips() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(CapturedClip(
            kind: .text, text: "plain", imageData: nil, preview: "plain", byteSize: 5,
            contentHash: ContentHash.of(text: "plain")
        ))
        #expect(store.ocrBackfillCandidates().isEmpty)
    }

    // MARK: - FuzzyMatcher over ocrText

    @Test func fuzzyMatcher_ranksImageByOCRText() {
        let img = imageItem(ocrText: "Invoice total 4200 dollars")
        let other = imageItem(ocrText: "unrelated receipt")
        let result = FuzzyMatcher.rank([img, other], query: "invoice")
        #expect(result.map(\.id) == [img.id])
    }

    @Test func fuzzyMatcher_emptyOCRSentinelNeverMatches() {
        let img = imageItem(ocrText: "")   // OCRed-empty
        // A query can't match a "" transcript (only "Image · WxH" preview remains).
        #expect(FuzzyMatcher.rank([img], query: "anything").isEmpty)
    }

    @Test func fuzzyMatcher_textClipsUnchanged() {
        // Text clips carry nil ocrText; searchableText returns their text, so
        // ranking is byte-identical to before.
        let a = textItem("swift concurrency notes")
        let b = textItem("grocery list")
        #expect(FuzzyMatcher.rank([a, b], query: "concurrency").map(\.id) == [a.id])
    }

    // MARK: - VM search integration

    @Test func viewModel_searchFindsImageByOCRText() {
        let img = imageItem(ocrText: "quarterly earnings report")
        let text = textItem("hello there")
        let vm = HistoryPanelViewModel(items: [img, text], onBuiltin: { _, _ in }, onDismiss: {})
        vm.query = "earnings"
        #expect(vm.filtered.map(\.id) == [img.id])
    }

    // MARK: - OCRService orchestration (injected recognizer, no real Vision)

    @Test func service_recognizeOnCapture_storesTranscript() async {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let service = OCRService(store: store, recognize: { _ in "recognized text" })
        let id = store.add(imageClip([5, 5, 5, 5]))
        service.recognizeOnCapture(id: id, png: Data([5, 5, 5, 5]))

        await waitFor { store.items.first?.ocrText == "recognized text" }
        #expect(store.items.first?.ocrText == "recognized text")
    }

    @Test func service_recognizeOnCapture_nilResultLeavesNil() async {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        // A nil recognizer result (Vision unavailable / error) must NOT be stored
        // — the clip stays never-OCRed so a later backfill can retry.
        let service = OCRService(store: store, recognize: { _ in nil })
        let id = store.add(imageClip([6, 6, 6, 6]))
        service.recognizeOnCapture(id: id, png: Data([6, 6, 6, 6]))

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.items.first?.ocrText == nil)
    }

    @Test func service_backfill_processesOnlyCandidates() async {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let neverID = store.add(imageClip([7, 7, 7, 7]))
        let doneID = store.add(imageClip([8, 8, 8, 8]))
        store.setOCRText(id: doneID, text: "manual")

        let service = OCRService(store: store, recognize: { _ in "backfilled" }, backfillDelay: 0)
        service.startBackfill()

        await waitFor { store.items.contains { $0.id == neverID && $0.ocrText == "backfilled" } }
        // The already-OCRed clip keeps its manual transcript (not a candidate).
        #expect(store.items.first(where: { $0.id == doneID })?.ocrText == "manual")
        #expect(store.items.first(where: { $0.id == neverID })?.ocrText == "backfilled")
    }

    /// Poll `condition` up to ~2s so async OCR tasks settle without a fixed sleep.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
