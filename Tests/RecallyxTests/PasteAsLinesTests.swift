import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Pure-logic coverage for the "Paste as lines" feature. The mechanism is a
/// per-line ⌘V with synthesized ⌥Return keystrokes between lines; the actual
/// CGEvent paste/Return into another app is HID/AppKit runtime behavior (verified
/// attended via the debug harness, like the synth-⌘V/⌘C paths) — not unit-tested
/// here. The line-splitting + "which lines paste" decision and the snapshot
/// save/restore wiring are pure/testable and covered below.
@MainActor
@Suite("Paste as lines")
struct PasteAsLinesTests {
    // MARK: - newline chord

    @Test func newlineFlags_isOptionReturn() {
        // ⌥Return — Claude Code's literal-newline chord; the fixed (no longer
        // configurable) newline keystroke between pasted lines.
        #expect(Paster.newlineFlags == .maskAlternate)
    }

    // MARK: - isTypeable (large-text cap + empty guard)

    @Test func isTypeable_acceptsShortText() {
        #expect(Paster.isTypeable("hello\nworld"))
    }

    @Test func isTypeable_acceptsTextAtTheCap() {
        let atCap = String(repeating: "a", count: Paster.maxTypeableLength)
        #expect(Paster.isTypeable(atCap))
    }

    @Test func isTypeable_rejectsTextOverTheCap() {
        let overCap = String(repeating: "a", count: Paster.maxTypeableLength + 1)
        #expect(!Paster.isTypeable(overCap))
    }

    @Test func isTypeable_rejectsEmpty() {
        #expect(!Paster.isTypeable(""))
    }

    @Test func isTypeable_rejectsWhitespaceOnly() {
        #expect(!Paster.isTypeable("   \n\t  "))
    }

    // MARK: - splitLines (preserve empty lines)

    @Test func splitLines_singleLineHasNoNewlines() {
        #expect(Paster.splitLines("hello") == ["hello"])
    }

    @Test func splitLines_splitsOnNewline() {
        #expect(Paster.splitLines("a\nb\nc") == ["a", "b", "c"])
    }

    @Test func splitLines_preservesInteriorEmptyLines() {
        // A blank line between paragraphs must survive as an empty element so the
        // paste emits its newline.
        #expect(Paster.splitLines("a\n\nb") == ["a", "", "b"])
    }

    @Test func splitLines_preservesLeadingAndTrailingEmptyLines() {
        #expect(Paster.splitLines("\na\n") == ["", "a", ""])
    }

    @Test func splitLines_emptyStringIsOneEmptyLine() {
        #expect(Paster.splitLines("") == [""])
    }

    // MARK: - shouldPasteLine (paste vs. newline-only)

    @Test func shouldPasteLine_pastesNonEmpty() {
        #expect(Paster.shouldPasteLine("hello"))
    }

    @Test func shouldPasteLine_skipsEmpty() {
        // Empty line → just the newline keystroke, no ⌘V (pasting "" would clear
        // the clipboard for nothing).
        #expect(!Paster.shouldPasteLine(""))
    }

    @Test func shouldPasteLine_pastesWhitespaceLine() {
        // A line of spaces is content the user wants pasted (indentation), not an
        // empty line — keep it.
        #expect(Paster.shouldPasteLine("   "))
    }

    // MARK: - line/paste mapping (the iteration contract typeText follows)

    /// Mirror typeText's loop: for each line, emit a newline before all but the
    /// first, and a paste only for non-empty lines.
    private func plan(_ text: String) -> (newlines: Int, pastes: Int) {
        let lines = Paster.splitLines(text)
        let newlines = max(0, lines.count - 1)
        let pastes = lines.filter(Paster.shouldPasteLine).count
        return (newlines, pastes)
    }

    @Test func plan_singleLinePastesOnceNoNewline() {
        let p = plan("hello")
        #expect(p == (newlines: 0, pastes: 1))
    }

    @Test func plan_twoLinesPasteTwiceOneNewline() {
        let p = plan("a\nb")
        #expect(p == (newlines: 1, pastes: 2))
    }

    @Test func plan_blankInteriorLineAddsNewlineNotPaste() {
        // "a\n\nb": 3 lines → 2 newlines, but only 2 pastes (the blank line is
        // newline-only).
        let p = plan("a\n\nb")
        #expect(p == (newlines: 2, pastes: 2))
    }

    // MARK: - snapshot save/restore wiring

    private func freshBoard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.macrosak.recallyx.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func typeText_restoresOriginalClipboardAndMarksWrites() async {
        let pb = freshBoard()
        pb.setString("user's original clip", forType: .string)

        var marks = 0
        // No sourceApp → no activation sleep; the synth ⌘V/Return events post to
        // the HID tap but land nowhere in the test process. The observable
        // contract here is the clipboard restore + markSelfWrite count.
        await Paster.typeText(
            "one\ntwo",
            lineDelay: 0,
            markSelfWrite: { marks += 1 },
            pasteboard: pb,
            into: nil
        )

        // Clipboard is back to the user's original after borrowing it per line.
        #expect(pb.string(forType: .string) == "user's original clip")
        // One mark per pasted line (2) plus one for the final restore.
        #expect(marks == 3)
    }

    @Test func typeText_emptyLinesDontPasteOrMarkExtra() async {
        let pb = freshBoard()
        pb.setString("orig", forType: .string)

        var marks = 0
        // "a\n\nb" → 2 pasted lines (the blank line is newline-only) + 1 restore.
        await Paster.typeText(
            "a\n\nb",
            lineDelay: 0,
            markSelfWrite: { marks += 1 },
            pasteboard: pb,
            into: nil
        )

        #expect(pb.string(forType: .string) == "orig")
        #expect(marks == 3)
    }

    // MARK: - BuiltinAction wiring (text-only)

    @Test func pasteAsLines_offeredForTextOnly() {
        let textEntries = BuiltinAction.entries(for: .text)
        let imageEntries = BuiltinAction.entries(for: .image)
        #expect(textEntries.contains(.pasteAsLines))
        #expect(!imageEntries.contains(.pasteAsLines))
    }

    @Test func pasteAsLines_sitsRightAfterPaste() {
        let textEntries = BuiltinAction.entries(for: .text)
        let pasteIdx = textEntries.firstIndex(of: .paste)
        let linesIdx = textEntries.firstIndex(of: .pasteAsLines)
        #expect(pasteIdx != nil && linesIdx != nil)
        #expect(linesIdx == pasteIdx! + 1)
    }

    @Test func pasteAsLines_hasTitleAndIcon() {
        #expect(BuiltinAction.pasteAsLines.title == "Paste as lines")
        #expect(BuiltinAction.pasteAsLines.icon == "text.alignleft")
        #expect(BuiltinAction.pasteAsLines.isDanger == false)
    }
}
