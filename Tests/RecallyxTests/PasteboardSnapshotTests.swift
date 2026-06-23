import AppKit
import Testing
@testable import Recallyx

/// `PasteboardSnapshot` is the testable core of BUG B's fix: the synth-⌘C
/// selection grab overwrites the clipboard, so we snapshot it first and restore
/// it after. These tests drive a private, uniquely-named `NSPasteboard` (never
/// the system clipboard) so they stay hermetic. The synth-⌘C polling/timing
/// around the snapshot is AppKit-bound and verified by build + reasoning.
@MainActor
@Suite("PasteboardSnapshot")
struct PasteboardSnapshotTests {
    private func freshBoard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.macrosak.recallyx.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func restoresPlainTextAfterOverwrite() {
        let pb = freshBoard()
        pb.clearContents()
        pb.setString("user's original clip", forType: .string)

        let snap = PasteboardSnapshot.capture(from: pb)

        // Simulate the synth-⌘C clobber.
        pb.clearContents()
        pb.setString("the selection", forType: .string)
        #expect(pb.string(forType: .string) == "the selection")

        snap.restore(to: pb)
        #expect(pb.string(forType: .string) == "user's original clip")
    }

    @Test func preservesMultipleTypesOnRestore() {
        let pb = freshBoard()
        let html = NSPasteboard.PasteboardType.html
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: html)
        pb.clearContents()
        pb.writeObjects([item])

        let snap = PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("clobbered", forType: .string)

        snap.restore(to: pb)
        #expect(pb.string(forType: .string) == "plain")
        #expect(pb.string(forType: html) == "<b>rich</b>")
    }

    @Test func emptySnapshotRestoresToEmpty() {
        let pb = freshBoard() // nothing written
        let snap = PasteboardSnapshot.capture(from: pb)

        pb.clearContents()
        pb.setString("clobbered", forType: .string)

        snap.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }
}
