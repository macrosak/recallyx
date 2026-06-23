import AppKit
import ApplicationServices
import Foundation
import RecallyxCore

enum AccessibilityError: LocalizedError {
    case notTrusted
    case noFocusedElement
    case noSelection
    case readFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Accessibility permission required"
        case .noFocusedElement: return "No focused element"
        case .noSelection: return "No text selected"
        case .readFailed(let err): return "Cannot read selection (\(err.rawValue))"
        }
    }
}

/// Reads the current selection via the system-wide Accessibility element, for
/// the ⌃⇧V transform-selection flow. Adapted (trimmed) from AI Replace — Recallyx
/// never writes selection back; transformed results are pasted via synth ⌘V, so
/// we only need the *read* path plus the one-prompt-per-session permission flow.
@MainActor
final class AccessibilityClient {
    private var promptShownThisSession = false

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    @discardableResult
    func ensureTrustedOrPrompt() -> Bool {
        if isTrusted() { return true }
        if !promptShownThisSession {
            promptShownThisSession = true
            showAlert()
        }
        return false
    }

    /// The currently selected text in the focused element, plus the frontmost
    /// app (so a later paste can re-activate it). Throws if nothing is selected.
    func captureSelection() throws -> (text: String, sourceApp: NSRunningApplication?) {
        guard isTrusted() else { throw AccessibilityError.notTrusted }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let fStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard fStatus == .success, let focused else { throw AccessibilityError.noFocusedElement }
        let element = focused as! AXUIElement

        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard status == .success else { throw AccessibilityError.readFailed(status) }
        guard let text = value as? String, !text.isEmpty else { throw AccessibilityError.noSelection }

        return (text, NSWorkspace.shared.frontmostApplication)
    }

    /// Fallback for apps whose AX tree doesn't expose `kAXSelectedText` reads
    /// (Chromium/Gmail — same family as the silent-write-drop lesson):
    /// synthesize ⌘C and watch the pasteboard's `changeCount`. No bump within
    /// the window ⇒ nothing was selected.
    ///
    /// The synth-⌘C overwrites whatever the user had on the clipboard, so we
    /// snapshot it first and **restore it afterwards** — the selection is pushed
    /// to history by the caller's `store.add`, so we don't need to leave it on
    /// the live pasteboard, and *not* restoring would silently eat the user's
    /// prior clip. We restore only after reading the copied text, then invoke
    /// `markSelfWrite` (wired to the watcher) so the watcher's next tick treats
    /// the restored content as our own write and won't recapture/bump it.
    func captureSelectionViaCopy(
        markSelfWrite: (() -> Void)? = nil
    ) async throws -> (text: String, sourceApp: NSRunningApplication?) {
        guard isTrusted() else { throw AccessibilityError.notTrusted }
        let sourceApp = NSWorkspace.shared.frontmostApplication

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let before = pasteboard.changeCount
        Paster.synthesizeCopyShortcut()

        // Apps commit the copy asynchronously; poll briefly (~500ms worst case).
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard pasteboard.changeCount != before else { continue }
            let copied = pasteboard.string(forType: .string)
            // Read first, then put the user's prior clipboard back and mark the
            // restore as a self-write so the watcher ignores it.
            snapshot.restore(to: pasteboard)
            markSelfWrite?()
            guard let text = copied, !text.isEmpty else {
                throw AccessibilityError.noSelection // copied, but not text
            }
            Log.info("⌘C fallback captured len=\(text.count) — clipboard restored")
            return (text, sourceApp)
        }
        // Nothing was copied (no selection) — the pasteboard was never touched,
        // so there's nothing to restore.
        throw AccessibilityError.noSelection
    }

    private func showAlert() {
        let alert = NSAlert()
        alert.messageText = "Recallyx needs Accessibility permission"
        alert.informativeText = """
        To grab the current selection (⌃⇧V) and paste results back into other apps, Recallyx needs Accessibility access. Enable it in System Settings → Privacy & Security → Accessibility.

        After granting access, quit and relaunch the app (permissions are read only at process start).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A non-lossy snapshot of the pasteboard's contents, so a transient overwrite
/// (the synth-⌘C selection grab) can put the user's clipboard back exactly as it
/// was — preserving every type on every item, not just the plain-text flavor.
///
/// Kept as a small value type so the capture/restore round-trip is testable in
/// isolation (the synth-⌘C polling around it is AppKit/timing-bound).
struct PasteboardSnapshot {
    /// One entry per original `NSPasteboardItem`: each type paired with its data.
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// Read every item/type currently on `pasteboard` into a detached copy.
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var byType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { byType[type] = data }
            }
            return byType
        }
        return PasteboardSnapshot(items: items)
    }

    /// Rewrite the captured items back onto `pasteboard`, replacing whatever is
    /// there now. An empty snapshot still clears (the user had an empty board).
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let rebuilt = items.compactMap { byType -> NSPasteboardItem? in
            guard !byType.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in byType { item.setData(data, forType: type) }
            return item
        }
        if !rebuilt.isEmpty { pasteboard.writeObjects(rebuilt) }
    }
}
