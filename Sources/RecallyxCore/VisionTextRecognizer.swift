import Foundation
#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO
#endif

/// Apple Vision text recognition (`VNRecognizeTextRequest`) — the same OCR
/// engine Preview / Live Text use. Wrapped in `#if canImport(Vision)` with a
/// nil-result fallback (mirrors `AppleClient`) so `RecallyxCore` stays buildable
/// on toolchains without the framework. Vision is present on macOS 13+ and iOS,
/// so this is a live path on every shipping build.
public enum VisionTextRecognizer {
    /// OCR the PNG and return the recognized text (lines joined by `\n`).
    ///
    /// Return contract, matched to the `HistoryItem.ocrText` sentinel:
    ///   • non-empty string → recognized text
    ///   • `""` → the request ran but found no text (caller stores the sentinel)
    ///   • `nil` → Vision is unavailable, or decoding / the request failed
    ///     (caller stores **nothing**, leaving the clip for a later backfill
    ///     retry rather than marking it permanently empty).
    ///
    /// Runs the (synchronous, CPU-heavy) Vision request on the calling context —
    /// callers invoke it from an off-main `Task.detached`. `perform` is
    /// synchronous, so results are read straight off the request afterwards (no
    /// completion handler / continuation: Vision invokes a completion handler
    /// with the error *and* `perform` throws, so bridging both would resume a
    /// continuation twice and crash).
    public static func recognize(png: Data) async -> String? {
        #if canImport(Vision)
        guard let cgImage = decodeCGImage(png) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return ""
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
        #else
        return nil
        #endif
    }

    #if canImport(Vision)
    private static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    #endif
}
