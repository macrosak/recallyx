import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Recallyx
@testable import RecallyxCore

@Suite("Shortcut")
struct ShortcutTests {
    private func make(
        keyCode: Int = kVK_ANSI_V,
        modifiers: Int = cmdKey | shiftKey,
        label: String = "v",
        enabled: Bool = true
    ) -> Shortcut {
        Shortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers), keyLabel: label, enabled: enabled)
    }

    // MARK: Glyphs

    @Test func glyphs_canonicalModifierOrder() {
        let s = make(modifiers: cmdKey | shiftKey | controlKey | optionKey)
        #expect(s.glyphs == ["⌃", "⌥", "⇧", "⌘", "V"])
    }

    @Test func glyphs_uppercasesLetterForDisplayOnly() {
        let s = make(label: "v")
        #expect(s.glyphs.last == "V")
        #expect(s.keyLabel == "v")
    }

    @Test func glyphs_specialKeyNameKeptVerbatim() {
        let s = make(keyCode: kVK_Space, modifiers: cmdKey, label: "Space")
        #expect(s.glyphs == ["⌘", "Space"])
    }

    // MARK: Modifier mapping

    @Test func carbonModifiers_mapsEachFlag() {
        #expect(Shortcut.carbonModifiers(from: [.command]) == UInt32(cmdKey))
        #expect(Shortcut.carbonModifiers(from: [.shift]) == UInt32(shiftKey))
        #expect(Shortcut.carbonModifiers(from: [.control]) == UInt32(controlKey))
        #expect(Shortcut.carbonModifiers(from: [.option]) == UInt32(optionKey))
        #expect(Shortcut.carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey | shiftKey))
    }

    @Test func carbonModifiers_ignoresNonHotkeyFlags() {
        #expect(Shortcut.carbonModifiers(from: [.capsLock, .function]) == 0)
        #expect(Shortcut.carbonModifiers(from: []) == 0)
    }

    // MARK: Codable

    @Test func codable_roundTrips() throws {
        let original = make(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey, label: "←")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    // MARK: Key equivalents

    @Test func keyEquivalent_isLowercaseWithShiftInModifiers() {
        // Uppercase KeyEquivalent implies ⇧ in SwiftUI — must not double-apply.
        let s = make(modifiers: cmdKey | shiftKey, label: "v")
        #expect(s.keyEquivalent?.character == "v")
        #expect(s.eventModifiers == [.shift, .command])
    }

    @Test func keyEquivalent_shiftedNumberKeepsBaseCharacter() {
        let s = make(keyCode: kVK_ANSI_7, modifiers: cmdKey | shiftKey, label: "7")
        #expect(s.keyEquivalent?.character == "7")
        #expect(s.eventModifiers.contains(.shift))
    }

    @Test func keyEquivalent_specialKey() {
        let s = make(keyCode: kVK_LeftArrow, modifiers: controlKey, label: "←")
        #expect(s.keyEquivalent?.character == KeyEquivalent.leftArrow.character)
    }

    @Test func keyEquivalent_fKeyHasNone() {
        let s = make(keyCode: kVK_F5, modifiers: cmdKey, label: "F5")
        #expect(s.keyEquivalent == nil)
        #expect(s.keyboardShortcut == nil)
    }

    @Test func keyboardShortcut_nilWhenDisabled() {
        let s = make(enabled: false)
        #expect(s.keyboardShortcut == nil)
    }

    // MARK: Validation

    @Test func validate_shiftOnlyFails() {
        let candidate = make(modifiers: shiftKey)
        #expect(Shortcut.validate(candidate, against: .transformSelectionDefault, otherAction: .transformSelection) == .noModifier)
    }

    @Test func validate_bareKeyFails() {
        let candidate = make(modifiers: 0)
        #expect(Shortcut.validate(candidate, against: .transformSelectionDefault, otherAction: .transformSelection) == .noModifier)
    }

    @Test func validate_conflictWithOtherBinding() {
        let candidate = make(modifiers: controlKey | shiftKey) // == transform default
        #expect(Shortcut.validate(candidate, against: .transformSelectionDefault, otherAction: .transformSelection) == .conflict(.transformSelection))
    }

    @Test func validate_conflictIgnoredWhenOtherDisabled() {
        var other = Shortcut.transformSelectionDefault
        other.enabled = false
        let candidate = make(modifiers: controlKey | shiftKey)
        #expect(Shortcut.validate(candidate, against: other, otherAction: .transformSelection) == nil)
    }

    @Test func validate_systemReservedCombos() {
        let cmdQ = make(keyCode: kVK_ANSI_Q, modifiers: cmdKey, label: "q")
        let cmdW = make(keyCode: kVK_ANSI_W, modifiers: cmdKey, label: "w")
        let cmdTab = make(keyCode: kVK_Tab, modifiers: cmdKey, label: "Tab")
        #expect(Shortcut.validate(cmdQ, against: .transformSelectionDefault, otherAction: .transformSelection) == .systemReserved)
        #expect(Shortcut.validate(cmdW, against: .transformSelectionDefault, otherAction: .transformSelection) == .systemReserved)
        #expect(Shortcut.validate(cmdTab, against: .transformSelectionDefault, otherAction: .transformSelection) == .systemReserved)
    }

    @Test func validate_reservedComboWithExtraModifierAllowed() {
        // Only the exact denylist entries are blocked; ⌘⇧Q is the user's call.
        let cmdShiftQ = make(keyCode: kVK_ANSI_Q, modifiers: cmdKey | shiftKey, label: "q")
        #expect(Shortcut.validate(cmdShiftQ, against: .transformSelectionDefault, otherAction: .transformSelection) == nil)
    }

    @Test func validate_cleanComboPasses() {
        let candidate = make(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey, label: "k")
        #expect(Shortcut.validate(candidate, against: .transformSelectionDefault, otherAction: .transformSelection) == nil)
    }
}
