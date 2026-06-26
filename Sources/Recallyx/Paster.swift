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
    static func setClipboardText(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    // MARK: - Paste line-by-line (the "Paste as lines" mechanism)

    /// The newline chord posted between lines: **⌥Return** (Option-Return) — Claude
    /// Code's literal-newline chord, so a plain Return doesn't submit in
    /// submit-on-Enter TUIs. Fixed (no longer user-configurable).
    nonisolated static let newlineFlags: CGEventFlags = .maskAlternate

    /// Soft cap on how long a clip we'll paste line-by-line. The line-by-line
    /// paste is slow (a ⌘V + settle per line), so above this it's a poor
    /// experience and we'd rather flash a notice than make the user watch a 1 MB
    /// clip tap out. Pure `isTypeable(_:)` gates this so it's unit-testable.
    nonisolated static let maxTypeableLength = 10_000

    /// Whether a clip is short enough to paste line-by-line (pure; tested).
    /// Empty/whitespace-only text isn't worth pasting either.
    nonisolated static func isTypeable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= maxTypeableLength
    }

    /// Default inter-step delay (microseconds) between a per-line ⌘V and the next
    /// newline/paste, so the paste lands before the next keystroke. Terminals can
    /// drop events that arrive too fast; ~30ms is a safe middle ground.
    nonisolated static let defaultLineDelayMicros: UInt32 = 30_000

    /// Settle (microseconds) after the final per-line ⌘V before restoring the
    /// user's clipboard. The synthesized ⌘V is delivered asynchronously (HID tap
    /// → window server → target app's event queue → the app reads
    /// `NSPasteboard.general`); restoring too soon clobbers the clip before the
    /// target reads it, so the last line pastes the *old* clipboard or nothing.
    /// Larger than `defaultLineDelayMicros` because there's no further keystroke
    /// to mask the latency. ~250ms.
    nonisolated static let restoreSettleMicros: UInt32 = 250_000

    /// Split `text` into lines on `\n`, preserving empty lines (so blank lines in
    /// the clip become blank lines in the output). Pure; unit-tested. This is the
    /// unit the line-by-line paste iterates over.
    nonisolated static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Whether a given line should be pasted (a ⌘V) vs. skipped. Empty lines emit
    /// only the newline keystroke — pasting an empty string would clear the
    /// clipboard and synth-⌘V nothing. Pure; unit-tested.
    nonisolated static func shouldPasteLine(_ line: String) -> Bool {
        !line.isEmpty
    }

    /// Activate `sourceApp`, then paste `text` **line by line**: each line is
    /// pasted with a single ⌘V and the newlines between lines are synthesized as
    /// the ⌥Return chord (`newlineFlags`).
    ///
    /// Why line-by-line instead of one paste: terminals' bracketed-paste mode
    /// collapses a multi-line ⌘V into a `[Pasted text #N]` placeholder. A
    /// *single-line* ⌘V never trips that, and a real Return keystroke between
    /// lines is what terminals read. This also handles all Unicode correctly
    /// (a real paste, not synthesized typing — synthesized unicode keystrokes are
    /// dropped by terminals that read the keycode instead of the payload).
    ///
    /// The pasteboard is borrowed per line, so the user's clipboard is snapshotted
    /// up front and restored at the end (the AccessibilityClient save/restore
    /// pattern). Each clipboard write — every line plus the final restore — is
    /// marked self-written so the watcher bumps/ignores rather than capturing our
    /// own paste payloads. Caller should pre-check `isTypeable(_:)`.
    static func typeText(
        _ text: String,
        lineDelay: UInt32 = defaultLineDelayMicros,
        markSelfWrite: (() -> Void)? = nil,
        pasteboard: NSPasteboard = .general,
        into sourceApp: NSRunningApplication?
    ) async {
        let lines = splitLines(text)
        // Snapshot the user's clipboard so we can restore it after borrowing the
        // pasteboard for each line's ⌘V (non-lossy: every type on every item).
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        Log.info("typeText start lines=\(lines.count) chars=\(text.count) sourceApp=\(sourceApp?.bundleIdentifier ?? "nil") lineDelay=\(lineDelay)")

        if let sourceApp {
            sourceApp.activate(options: [])
            // Let the activation settle before the keystrokes, else the first ⌘V
            // can land in our own app (mirrors activateAndPaste).
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let returnKey: CGKeyCode = 0x24 // kVK_Return
        var pastedLines = 0

        for (index, line) in lines.enumerated() {
            if index > 0 {
                postKey(source: source, virtualKey: returnKey, flags: newlineFlags)
                if lineDelay > 0 { usleep(lineDelay) }
            }
            if shouldPasteLine(line) {
                setClipboardText(line, to: pasteboard)
                markSelfWrite?()
                synthesizePasteShortcut()
                pastedLines += 1
                if lineDelay > 0 { usleep(lineDelay) }
            }
        }

        // Let the final per-line ⌘V be consumed by the target before we restore
        // the clipboard — restoring too soon races the paste (see the constant).
        if pastedLines > 0 { usleep(restoreSettleMicros) }

        // Restore the user's original clipboard and mark the restore as our own
        // write so the watcher's next tick ignores it.
        snapshot.restore(to: pasteboard)
        markSelfWrite?()
        Log.info("typeText done pastedLines=\(pastedLines)/\(lines.count)")
    }

    /// Post a down/up keystroke for a real virtual key with modifier flags
    /// (used for the newline Return chord between lines).
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
