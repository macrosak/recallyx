import AppKit
import ApplicationServices
import Foundation

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
