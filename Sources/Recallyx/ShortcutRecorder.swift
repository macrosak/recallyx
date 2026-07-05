import AppKit
import Carbon.HIToolbox
import SwiftUI
import RecallyxCore

/// The app delegate's hotkey seam, handed down to the Settings UI. `apply` /
/// `applyAction` are the single mutation points (Carbon-then-settings);
/// `suspend`/`resume` bracket recording so the live hotkeys can't swallow the
/// keys being captured.
@MainActor
struct ShortcutActions {
    /// Register one of the two built-in app hotkeys.
    let apply: (HotkeyAction, Shortcut) -> HotkeyManager.ApplyResult
    /// Register a saved action's global hotkey (keyed by `Action.id.uuidString`).
    let applyAction: (_ token: String, Shortcut) -> HotkeyManager.ApplyResult
    let suspend: () -> Void
    let resume: () -> Void
}

/// Click-to-record shortcut field for one hotkey. Idle shows the current
/// binding's keycaps (or "Disabled"); click → "Press keys…" and the next
/// valid combo is validated (via the injected `validate` closure), then
/// registered + saved live (via `apply`). ✕ disables. Errors surface through the
/// `error` binding (the parent row's description slot, matching the
/// launch-at-login pattern).
///
/// Fully closure-driven so it serves both the two built-in app hotkeys (General
/// tab) and per-action hotkeys (Actions tab) — the two differ only in how a
/// candidate is validated, registered, and disabled.
struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let suspend: () -> Void
    let resume: () -> Void
    /// Pure decision: validate a freshly recorded candidate → an error message
    /// to show, or nil to proceed to `apply`.
    let validate: (Shortcut) -> String?
    /// Register the candidate (Carbon-then-settings).
    let apply: (Shortcut) -> HotkeyManager.ApplyResult
    /// Clear/disable this binding (the ✕ button).
    let disableBinding: () -> Void
    @Binding var error: String?
    let theme: SettingsTheme

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? cancel() : begin()
            } label: {
                if recording {
                    fieldText("Press keys…", color: theme.textDim, border: theme.accent)
                } else if shortcut.enabled {
                    ShortcutChips(keys: shortcut.glyphs, theme: theme)
                } else {
                    fieldText("Disabled", color: theme.textFaint, border: theme.btnBorder)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if shortcut.enabled && !recording {
                Button(action: disable) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Disable this shortcut")
            }
        }
        .onDisappear { if recording { cancel() } }
        // The settings window losing key focus must end recording — otherwise
        // the local monitor (and the hotkey suspension) would dangle.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { cancel() }
        }
    }

    private func fieldText(_ label: String, color: Color, border: Color) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(minHeight: 20)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.segBg)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 0.5))
            )
    }

    // MARK: - Recording lifecycle

    private func begin() {
        error = nil
        suspend()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Modifiers held alone: stay recording, let the event through.
            guard event.type == .keyDown else { return event }
            handle(event)
            return nil // consume — the keypress is ours
        }
    }

    /// Every exit path funnels here so the monitor teardown and the hotkey
    /// resume can't come apart.
    private func end(with message: String?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        error = message
        resume()
    }

    private func cancel() { end(with: nil) }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape, Shortcut.carbonModifiers(from: event.modifierFlags) == 0 {
            cancel()
            return
        }
        guard let candidate = Shortcut.from(event: event) else { return } // unusable key — keep recording

        if let message = validate(candidate) {
            end(with: message)
            return
        }
        switch apply(candidate) {
        case .ok, .disabled:
            end(with: nil)
        case .failed(let status):
            end(with: status == OSStatus(eventHotKeyExistsErr)
                ? "That shortcut is in use by another app."
                : "Couldn't register that shortcut.")
        }
    }

    private func disable() {
        if recording { cancel() }
        error = nil
        disableBinding()
    }
}

// MARK: - Message helpers

extension ShortcutRecorder {
    /// Compose the message for a built-in app-hotkey validation failure (General
    /// tab). `otherName` is the human name of the one other app hotkey.
    static func message(for error: ShortcutError, otherName: String) -> String {
        switch error {
        case .noModifier: return "Add ⌘, ⌃, or ⌥."
        case .conflict: return "Already used by \(otherName)."
        case .systemReserved: return "That shortcut is reserved by macOS."
        }
    }

    /// Compose the message for a per-action-hotkey validation failure (Actions tab).
    static func message(for error: ActionShortcutError) -> String {
        switch error {
        case .noModifier: return "Add ⌘, ⌃, or ⌥."
        case .systemReserved: return "That shortcut is reserved by macOS."
        case .conflictApp(let action):
            switch action {
            case .showHistory: return "Already used by Search & paste history."
            case .transformSelection: return "Already used by Transform selection."
            }
        case .conflictAction(let name): return "Already used by “\(name)”."
        }
    }
}
