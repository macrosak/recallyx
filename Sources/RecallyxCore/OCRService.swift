import Foundation

/// Runs Apple Vision OCR on image clips and writes the recognized transcript
/// back to the `HistoryStore`, so screenshots become findable by the text they
/// contain (`HistoryItem.ocrText` → `FuzzyMatcher`). Two entry points:
///   • `recognizeOnCapture(id:png:)` — kicked when the watcher stores a fresh
///     image clip; OCRs off-main and stores the result.
///   • `startBackfill()` — a one-time, throttled sweep of existing image clips
///     that were never OCRed, run once on launch.
///
/// The Vision call is injected (`recognize`) so tests stay hermetic and never
/// invoke real OCR; production wires `VisionTextRecognizer.recognize`. All store
/// writes hop to the MainActor. Logging is content-free (counts / lengths only).
@MainActor
public final class OCRService {
    private let store: HistoryStore
    /// PNG bytes → recognized text. Sendable + async so it runs off the main
    /// actor. See `VisionTextRecognizer.recognize` for the nil / "" contract.
    private let recognize: @Sendable (Data) async -> String?
    /// Delay between backfill items so a login-time sweep doesn't thrash CPU.
    private let backfillDelay: TimeInterval
    private var backfillTask: Task<Void, Never>?

    public init(
        store: HistoryStore,
        recognize: @escaping @Sendable (Data) async -> String? = { await VisionTextRecognizer.recognize(png: $0) },
        backfillDelay: TimeInterval = 0.15
    ) {
        self.store = store
        self.recognize = recognize
        self.backfillDelay = backfillDelay
    }

    /// Capture-time OCR: recognize `png` off-main, then store the transcript on
    /// clip `id`. A nil recognizer result (Vision unavailable / errored) stores
    /// nothing — the clip stays `ocrText == nil` and a later backfill retries.
    /// An empty result is stored as the `""` sentinel by `setOCRText`.
    public func recognizeOnCapture(id: UUID, png: Data) {
        Task.detached(priority: .background) { [weak self, recognize] in
            guard let text = await recognize(png) else { return }
            await MainActor.run { self?.store.setOCRText(id: id, text: text) }
        }
    }

    /// One-time, throttled backfill of image clips that were never OCRed. Serial,
    /// low priority, with `backfillDelay` between items so it doesn't spike CPU at
    /// login. Progress persists implicitly — each result saves, so a relaunch just
    /// continues with the remaining nils. Idempotent: re-invoking cancels any
    /// in-flight sweep and re-derives the work list from the current store.
    public func startBackfill() {
        backfillTask?.cancel()
        let work = store.ocrBackfillCandidates()
        guard !work.isEmpty else { return }
        Log.info("ocr backfill: \(work.count) image(s) queued")
        backfillTask = Task { [weak self, recognize, backfillDelay] in
            var processed = 0
            for candidate in work {
                if Task.isCancelled { break }
                let url = candidate.imageURL
                // Read the file + OCR off the main actor.
                let text: String? = await Task.detached(priority: .background) {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return await recognize(data)
                }.value
                if Task.isCancelled { break }
                if let text { self?.store.setOCRText(id: candidate.id, text: text) }
                processed += 1
                try? await Task.sleep(nanoseconds: UInt64(max(0, backfillDelay) * 1_000_000_000))
            }
            Log.info("ocr backfill: finished (\(processed) processed)")
        }
    }
}
