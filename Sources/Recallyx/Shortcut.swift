import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One global hotkey binding: the Carbon-facing keyCode + modifier mask, plus a
/// display label captured at record time. Storing the label sidesteps the
/// keyCode→character `UCKeyTranslate` gymnastics; the trade-off is that the
/// label reflects the keyboard layout active when it was recorded.
struct Shortcut: Codable, Equatable {
    /// Virtual key code (kVK_* / NSEvent.keyCode) — what `RegisterEventHotKey` wants.
    var keyCode: UInt32
    /// Carbon cmdKey|shiftKey|controlKey|optionKey mask.
    var carbonModifiers: UInt32
    /// Unshifted base character ("v", "7") or a special-key name ("Space", "←", "F5").
    /// Kept lowercase for letters; `glyphs` uppercases for display only — an
    /// uppercase SwiftUI `KeyEquivalent` implies ⇧, which would double-apply
    /// with `.shift` carried in `eventModifiers`.
    var keyLabel: String
    var enabled: Bool

    static let searchHistoryDefault = Shortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "v",
        enabled: true
    )

    static let transformSelectionDefault = Shortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | shiftKey),
        keyLabel: "v",
        enabled: true
    )
}

// MARK: - Display / SwiftUI derivations

extension Shortcut {
    /// Keycap strings in Apple's canonical ⌃⌥⇧⌘ order, ending with the key.
    var glyphs: [String] {
        var out: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { out.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { out.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { out.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { out.append("⌘") }
        out.append(keyLabel.count == 1 ? keyLabel.uppercased() : keyLabel)
        return out
    }

    // Fully qualified: Carbon exports its own `EventModifiers` typealias.
    var eventModifiers: SwiftUI.EventModifiers {
        var out: SwiftUI.EventModifiers = []
        if carbonModifiers & UInt32(controlKey) != 0 { out.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { out.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { out.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { out.insert(.command) }
        return out
    }

    /// Lowercase key equivalent for menu items; nil for keys SwiftUI has no
    /// constant for (F-keys).
    var keyEquivalent: KeyEquivalent? {
        if let special = Self.specialKeyEquivalents[keyLabel] { return special }
        guard keyLabel.count == 1, let c = keyLabel.lowercased().first else { return nil }
        return KeyEquivalent(c)
    }

    /// Ready-to-use menu shortcut; nil when disabled (the menu item then shows
    /// no key hint) or when no `keyEquivalent` exists.
    var keyboardShortcut: KeyboardShortcut? {
        guard enabled, let key = keyEquivalent else { return nil }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    private static let specialKeyEquivalents: [String: KeyEquivalent] = [
        "Space": .space, "Return": .return, "Tab": .tab,
        "⌫": .delete, "⌦": .deleteForward,
        "←": .leftArrow, "→": .rightArrow, "↑": .upArrow, "↓": .downArrow,
        "↖": .home, "↘": .end, "⇞": .pageUp, "⇟": .pageDown,
    ]
}

// MARK: - Recording

extension Shortcut {
    /// Build a candidate from a recorder keyDown. Nil when the key yields no
    /// usable label (dead keys, unmapped function keys).
    static func from(event: NSEvent) -> Shortcut? {
        guard let label = keyLabel(for: event) else { return nil }
        return Shortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbonModifiers(from: event.modifierFlags),
            keyLabel: label,
            enabled: true
        )
    }

    /// Cocoa → Carbon modifier mask. Pure; unit-tested.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Special keys first (arrows/F-keys come back from `characters` as
    /// private-use Unicode, space/return/tab as whitespace), then the unshifted
    /// base character via `characters(byApplyingModifiers: [])` — NOT
    /// `charactersIgnoringModifiers`, which keeps ⇧ applied and would capture
    /// "V"/"&" instead of "v"/"7".
    private static func keyLabel(for event: NSEvent) -> String? {
        if let special = specialKeyLabels[Int(event.keyCode)] { return special }
        guard
            let chars = event.characters(byApplyingModifiers: []),
            chars.count == 1,
            let scalar = chars.unicodeScalars.first,
            scalar.value >= 0x20, // printable; no control chars
            !(0xF700...0xF8FF).contains(scalar.value) // no NSEvent function-key range
        else { return nil }
        return chars.lowercased()
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Return", kVK_Tab: "Tab",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

// MARK: - Validation

enum ShortcutError: Equatable {
    case noModifier
    case conflict(HotkeyAction)
    case systemReserved
}

extension Shortcut {
    /// Combos `RegisterEventHotKey` would happily grab globally, shadowing them
    /// in every app. Deliberately tiny — anything else is the user's call;
    /// ✕/re-record is the escape hatch.
    private static let systemReserved: [(keyCode: UInt32, modifiers: UInt32)] = [
        (UInt32(kVK_ANSI_Q), UInt32(cmdKey)), // ⌘Q
        (UInt32(kVK_ANSI_W), UInt32(cmdKey)), // ⌘W
        (UInt32(kVK_Tab), UInt32(cmdKey)),    // ⌘⇥
    ]

    /// Pure validation of a freshly recorded candidate against the other
    /// binding. Carbon-layer failures (combo taken by another app) surface
    /// separately via `HotkeyManager.apply`.
    static func validate(
        _ candidate: Shortcut,
        against other: Shortcut,
        otherAction: HotkeyAction
    ) -> ShortcutError? {
        if candidate.carbonModifiers & UInt32(cmdKey | controlKey | optionKey) == 0 {
            return .noModifier
        }
        if systemReserved.contains(where: {
            $0.keyCode == candidate.keyCode && $0.modifiers == candidate.carbonModifiers
        }) {
            return .systemReserved
        }
        if other.enabled,
           other.keyCode == candidate.keyCode,
           other.carbonModifiers == candidate.carbonModifiers {
            return .conflict(otherAction)
        }
        return nil
    }
}
