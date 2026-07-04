import Foundation
import Testing
@testable import RecallyxCore

@Suite("CapturedClip.forText factory")
struct CapturedClipTextTests {
    @Test("builds a text clip with derived preview / byteSize / hash")
    func buildsTextClip() throws {
        let clip = try #require(CapturedClip.forText("Hello, world", sourceAppName: "iPhone"))
        #expect(clip.kind == .text)
        #expect(clip.text == "Hello, world")
        #expect(clip.imageData == nil)
        #expect(clip.preview == "Hello, world")
        #expect(clip.byteSize == "Hello, world".utf8.count)
        #expect(clip.contentHash == ContentHash.of(text: "Hello, world"))
        #expect(clip.sourceAppName == "iPhone")
    }

    @Test("empty / whitespace-only text is dropped")
    func dropsSkippable() {
        #expect(CapturedClip.forText("") == nil)
        #expect(CapturedClip.forText("   \n\t ") == nil)
    }

    @Test("preview is trimmed and length-capped; full text is preserved")
    func trimsAndCapsPreview() throws {
        let raw = "  " + String(repeating: "a", count: 400) + "  "
        let clip = try #require(CapturedClip.forText(raw))
        #expect(clip.preview.count == 280)
        #expect(clip.preview == String(repeating: "a", count: 280))
        // The stored text keeps the original (untrimmed, uncapped) payload.
        #expect(clip.text == raw)
    }

    @Test("identical content produces identical dedupe hash")
    func stableHash() throws {
        let a = try #require(CapturedClip.forText("same"))
        let b = try #require(CapturedClip.forText("same", sourceAppName: "iPhone"))
        #expect(a.contentHash == b.contentHash)
    }
}
