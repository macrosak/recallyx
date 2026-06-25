import CoreGraphics
import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Pure-logic coverage for the "Paste as keystrokes" feature. The actual CGEvent
/// typing into another app is HID/AppKit runtime behavior (verified attended via
/// the debug harness, like the synth-⌘V/⌘C paths) — not unit-tested here.
@Suite("Paste as keystrokes")
struct PasteKeystrokesTests {
    // MARK: - NewlineKey → CGEventFlags mapping

    @Test func optionReturn_mapsToAlternateFlag() {
        #expect(NewlineKey.optionReturn.flags == .maskAlternate)
    }

    @Test func shiftReturn_mapsToShiftFlag() {
        #expect(NewlineKey.shiftReturn.flags == .maskShift)
    }

    @Test func plain_mapsToNoFlags() {
        #expect(NewlineKey.plain.flags == [])
    }

    @Test func defaultNewlineKey_isOptionReturn() {
        // Claude Code's literal-newline chord — the whole point of the default.
        #expect(NewlineKey.default == .optionReturn)
    }

    @Test func allCases_coverEveryKey() {
        #expect(NewlineKey.allCases.count == 3)
        #expect(Set(NewlineKey.allCases) == [.optionReturn, .shiftReturn, .plain])
    }

    @Test func titles_areNonEmptyAndDistinct() {
        let titles = NewlineKey.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test func newlineKey_codableRoundTrips() throws {
        for key in NewlineKey.allCases {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(NewlineKey.self, from: data)
            #expect(decoded == key)
        }
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

    // MARK: - BuiltinAction wiring (text-only)

    @Test func pasteAsKeystrokes_offeredForTextOnly() {
        let textEntries = BuiltinAction.entries(for: .text)
        let imageEntries = BuiltinAction.entries(for: .image)
        #expect(textEntries.contains(.pasteAsKeystrokes))
        #expect(!imageEntries.contains(.pasteAsKeystrokes))
    }

    @Test func pasteAsKeystrokes_sitsRightAfterPaste() {
        let textEntries = BuiltinAction.entries(for: .text)
        let pasteIdx = textEntries.firstIndex(of: .paste)
        let keysIdx = textEntries.firstIndex(of: .pasteAsKeystrokes)
        #expect(pasteIdx != nil && keysIdx != nil)
        #expect(keysIdx == pasteIdx! + 1)
    }

    @Test func pasteAsKeystrokes_hasTitleAndIcon() {
        #expect(BuiltinAction.pasteAsKeystrokes.title == "Paste as keystrokes")
        #expect(BuiltinAction.pasteAsKeystrokes.icon == "keyboard")
        #expect(BuiltinAction.pasteAsKeystrokes.isDanger == false)
    }
}
