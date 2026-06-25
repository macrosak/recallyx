import AppKit
import RecallyxCore

/// How a `\n` in a typed-out clip is keyed when "Paste as keystrokes" types the
/// clip out. A plain Return submits in many TUIs (Claude Code, chat inputs), so
/// newlines are sent as a modified Return instead. Pure value type; `Codable` so
/// it round-trips in `AppSettings`. The default is `.optionReturn` — Claude
/// Code's literal-newline chord.
enum NewlineKey: String, Codable, CaseIterable {
    /// ⌥Return — the literal-newline chord in Claude Code and many terminals.
    case optionReturn
    /// ⇧Return — the soft-newline chord in many web/chat inputs.
    case shiftReturn
    /// A bare Return — for fields where Return doesn't submit (multiline inputs).
    case plain

    static let `default`: NewlineKey = .optionReturn

    /// The CGEvent modifier flags posted with the Return keystroke for this key.
    var flags: CGEventFlags {
        switch self {
        case .optionReturn: return .maskAlternate
        case .shiftReturn: return .maskShift
        case .plain: return []
        }
    }

    /// Human-readable label for the Settings picker.
    var title: String {
        switch self {
        case .optionReturn: return "Option-Return (⌥↵)"
        case .shiftReturn: return "Shift-Return (⇧↵)"
        case .plain: return "Return (↵)"
        }
    }
}

/// Paste mechanics, extracted from AI Replace's `CorrectionController`:
/// pre-populate the clipboard, re-activate the source app, then post a
/// synthesized ⌘V at the HID event tap so the content lands where the user was
/// before the panel opened. The clipboard stays populated regardless, so a
/// failed synth still leaves the content one manual ⌘V away.
@MainActor
enum Paster {
    /// Put `text` on the clipboard and paste it into `sourceApp`.
    static func pasteText(_ text: String, into sourceApp: NSRunningApplication?) async {
        setClipboardText(text)
        await activateAndPaste(sourceApp: sourceApp)
    }

    /// Put text on the clipboard without pasting (the "Copy" action; also the
    /// first half of a paste, split out so the caller can mark the write as
    /// self-written before the watcher's next tick).
    static func setClipboardText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Image counterpart of `setClipboardText`. Writes the on-disk PNG bytes
    /// straight to the pasteboard under `.png` — no `NSImage` round-trip, so the
    /// pasted image is byte-identical to the captured original (no re-encode).
    /// Stored images are always normalized to PNG at capture, so `.png` is the
    /// correct type. The pasteboard is injectable for hermetic tests; callers
    /// use the `.general` default.
    static func setClipboardImage(data: Data, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    /// Activate the source app and synthesize ⌘V — the second half of a paste.
    static func activateAndPaste(sourceApp: NSRunningApplication?) async {
        if let sourceApp {
            sourceApp.activate(options: [])
            // Let the activation settle before the keystroke, else ⌘V can land
            // in our own app.
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        synthesizePasteShortcut()
    }

    // MARK: - Type as keystrokes

    /// Soft cap on how long a clip we'll type out as keystrokes. Typing is slow
    /// (per-character HID events), so above this it's a poor experience and we'd
    /// rather flash a notice than make the user watch a 1 MB clip tap out. Pure
    /// `isTypeable(_:)` gates this so it's unit-testable.
    nonisolated static let maxTypeableLength = 10_000

    /// Whether a clip is short enough to type out as keystrokes (pure; tested).
    /// Empty/whitespace-only text isn't worth typing either.
    nonisolated static func isTypeable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= maxTypeableLength
    }

    /// Default inter-keystroke delay (microseconds). Apps drop synthesized events
    /// if typed too fast; ~2ms is a safe middle ground for terminals.
    nonisolated static let defaultTypeDelayMicros: UInt32 = 2000

    /// Activate `sourceApp`, then type `text` out as real keystrokes (NOT a
    /// clipboard write + ⌘V). This dodges terminals' bracketed-paste mode, which
    /// collapses a multi-line paste into a `[Pasted text]` placeholder — typed
    /// keystrokes land as visible lines instead.
    ///
    /// Each character is posted via `keyboardSetUnicodeString` (layout- and
    /// keycode-independent, handles Unicode/emoji), and each `\n` is sent as the
    /// configured `NewlineKey` Return chord (a plain Return would submit in
    /// submit-on-Enter TUIs). No pasteboard is touched, so no `markSelfWrite()`
    /// is needed. Caller should pre-check `isTypeable(_:)`.
    static func typeText(
        _ text: String,
        newlineKey: NewlineKey,
        perCharDelay: UInt32 = defaultTypeDelayMicros,
        into sourceApp: NSRunningApplication?
    ) async {
        if let sourceApp {
            sourceApp.activate(options: [])
            // Let the activation settle before typing, else the first keystrokes
            // can land in our own app (mirrors activateAndPaste).
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        let newlineFlags = newlineKey.flags

        for character in text {
            if character == "\n" {
                postKey(source: source, virtualKey: returnKey, flags: newlineFlags)
            } else {
                postUnicode(source: source, string: String(character))
            }
            if perCharDelay > 0 { usleep(perCharDelay) }
        }
    }

    /// Post a down/up keystroke for a single Unicode scalar string via
    /// `keyboardSetUnicodeString` (virtual key is a placeholder — the unicode
    /// string is what the receiving app reads).
    private static func postUnicode(source: CGEventSource?, string: String) {
        let utf16 = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Post a down/up keystroke for a real virtual key with modifier flags
    /// (used for the newline Return chord).
    private static func postKey(source: CGEventSource?, virtualKey: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Synthesize ⌘C in the frontmost app — the capture-side counterpart of the
    /// ⌘V paste, for selections AX can't read (Chromium/Gmail).
    static func synthesizeCopyShortcut() {
        synthesizeCommandShortcut(0x08) // kVK_ANSI_C
    }

    private static func synthesizePasteShortcut() {
        synthesizeCommandShortcut(0x09) // kVK_ANSI_V
    }

    private static func synthesizeCommandShortcut(_ vKey: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
