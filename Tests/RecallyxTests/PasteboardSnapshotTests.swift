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

    // MARK: - harvestCopiedSelection (the late-copy restore decision)
    //
    // `captureSelectionViaCopy`'s poll loop and its final re-check both route the
    // "did a copy land? → read + restore + mark + report" decision through
    // `harvestCopiedSelection`. The synth-⌘C + real async timing stays
    // AppKit-bound; these tests drive the helper directly so the restore/return
    // logic (incl. the late-copy path that used to silently eat the clip) is
    // covered without the poll.

    /// The late-copy case: the app committed the selection onto the board, so
    /// `changeCount` has moved past `before`. The helper must read the text,
    /// restore the user's prior clip, fire `markSelfWrite`, and report it.
    @Test func harvestRestoresAndReportsLateCopy() {
        let pb = freshBoard()
        pb.setString("user's original clip", forType: .string)
        let snap = PasteboardSnapshot.capture(from: pb)
        let before = pb.changeCount

        // The slow app finally commits the grabbed selection.
        pb.clearContents()
        pb.setString("the selection", forType: .string)
        #expect(pb.changeCount != before)

        var marked = false
        let client = AccessibilityClient()
        let result = client.harvestCopiedSelection(
            from: pb, since: before, restoring: snap, markSelfWrite: { marked = true }
        )

        #expect(result == .captured("the selection"))
        #expect(marked) // restore was marked as a self-write
        // The user's clipboard is back — not silently lost.
        #expect(pb.string(forType: .string) == "user's original clip")
    }

    /// The genuinely-untouched case: no copy landed, `changeCount` unchanged.
    /// The helper reports `.pending` and leaves the board exactly as it was.
    @Test func harvestLeavesUntouchedBoardAlone() {
        let pb = freshBoard()
        pb.setString("user's original clip", forType: .string)
        let snap = PasteboardSnapshot.capture(from: pb)
        let before = pb.changeCount

        var marked = false
        let client = AccessibilityClient()
        let result = client.harvestCopiedSelection(
            from: pb, since: before, restoring: snap, markSelfWrite: { marked = true }
        )

        #expect(result == .pending)
        #expect(!marked) // nothing copied → no restore, no self-write
        #expect(pb.string(forType: .string) == "user's original clip")
    }

    /// A copy landed but it isn't text (e.g. an image-only selection): the helper
    /// still restores the user's clip + marks the write, and reports
    /// `.restoredNoText` so the caller throws `.noSelection` — without losing the
    /// prior clipboard.
    @Test func harvestRestoresOnNonTextCopy() {
        let pb = freshBoard()
        pb.setString("user's original clip", forType: .string)
        let snap = PasteboardSnapshot.capture(from: pb)
        let before = pb.changeCount

        // A non-text payload lands (no .string flavor).
        pb.clearContents()
        pb.setData(Data([0x1, 0x2, 0x3]), forType: .png)
        #expect(pb.changeCount != before)

        var marked = false
        let client = AccessibilityClient()
        let result = client.harvestCopiedSelection(
            from: pb, since: before, restoring: snap, markSelfWrite: { marked = true }
        )

        #expect(result == .restoredNoText)
        #expect(marked)
        #expect(pb.string(forType: .string) == "user's original clip")
    }
}
