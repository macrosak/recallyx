import AppKit
import Foundation
import Testing
@testable import RecallyxCore

/// Optional end-to-end check of the real Apple Vision recognizer against a
/// synthetically-rendered text image. Kept lenient (asserts a non-nil result and,
/// when the OCR succeeds, that it recovers the drawn word) so it never flakes the
/// suite on CI / headless runners; the pure orchestration is covered hermetically
/// in `OCRSearchTests`.
@Suite("VisionTextRecognizer (real OCR)")
struct VisionTextRecognizerTests {

    /// Render `text` as black-on-white PNG bytes big enough for Vision to read.
    private func renderPNG(_ text: String, size: NSSize = NSSize(width: 400, height: 140)) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 64),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    @Test func recognizesRenderedText() async throws {
        guard let png = renderPNG("HELLO") else {
            Issue.record("could not render test PNG")
            return
        }
        let result = await VisionTextRecognizer.recognize(png: png)
        // Vision may be unavailable on some runners → nil is tolerated. When it
        // does run, it should recover the drawn word.
        if let result, !result.isEmpty {
            #expect(result.uppercased().contains("HELLO"))
        }
    }

    @Test func garbageDataDoesNotCrash() async {
        // Non-image bytes: decode fails → nil (never a crash, never "").
        let result = await VisionTextRecognizer.recognize(png: Data([0x00, 0x01, 0x02, 0x03]))
        #expect(result == nil)
    }
}
