import AppKit

/// Paste mechanics, extracted from AI Replace's `CorrectionController`:
/// pre-populate the clipboard, re-activate the source app, then post a
/// synthesized ⌘V at the HID event tap so the content lands where the user was
/// before the panel opened. The clipboard stays populated regardless, so a
/// failed synth still leaves the content one manual ⌘V away.
@MainActor
enum Paster {
    /// Put `text` on the clipboard and paste it into `sourceApp`.
    static func pasteText(_ text: String, into sourceApp: NSRunningApplication?) async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        await activateAndPaste(sourceApp: sourceApp)
    }

    /// Put an image on the clipboard (as PNG) and paste it into `sourceApp`.
    static func pasteImage(_ image: NSImage, into sourceApp: NSRunningApplication?) async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        await activateAndPaste(sourceApp: sourceApp)
    }

    /// Just put text on the clipboard without pasting (the "Copy" action).
    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func activateAndPaste(sourceApp: NSRunningApplication?) async {
        if let sourceApp {
            sourceApp.activate(options: [])
            // Let the activation settle before the keystroke, else ⌘V can land
            // in our own app.
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        synthesizePasteShortcut()
    }

    private static func synthesizePasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
