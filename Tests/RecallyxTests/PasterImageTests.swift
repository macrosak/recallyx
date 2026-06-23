import AppKit
import Testing
@testable import Recallyx

/// `Paster.setClipboardImage(data:)` writes the on-disk PNG bytes straight to
/// the pasteboard so a pasted image clip is byte-identical to the captured
/// original (no `NSImage` re-encode round-trip). These tests drive a private,
/// uniquely-named `NSPasteboard` (never the system clipboard) so they stay
/// hermetic — same convention as the `PasteboardSnapshot` tests.
@MainActor
@Suite("Paster image paste")
struct PasterImageTests {
    private func freshBoard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.macrosak.recallyx.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    /// Known PNG bytes (a 2×2 solid image), produced once so the test has a
    /// fixed on-disk payload to round-trip through the pasteboard.
    private func samplePNGData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func writesPNGDataByteIdentical() {
        let pb = freshBoard()
        let data = samplePNGData()

        Paster.setClipboardImage(data: data, to: pb)

        let written = pb.data(forType: .png)
        #expect(written != nil)
        // The exact input bytes must come back out — proves no re-encode.
        #expect(written == data)
    }

    @Test func clearsPriorContentsBeforeWriting() {
        let pb = freshBoard()
        pb.clearContents()
        pb.setString("stale clip", forType: .string)

        Paster.setClipboardImage(data: samplePNGData(), to: pb)

        #expect(pb.string(forType: .string) == nil)
        #expect(pb.data(forType: .png) != nil)
    }
}
