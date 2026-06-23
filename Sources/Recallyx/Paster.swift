import AppKit
import RecallyxCore

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
