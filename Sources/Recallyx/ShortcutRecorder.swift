import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The app delegate's hotkey seam, handed down to the Settings UI. `apply` is
/// the single mutation point (Carbon-then-settings); `suspend`/`resume`
/// bracket recording so the live hotkeys can't swallow the keys being
/// captured.
@MainActor
struct ShortcutActions {
    let apply: (HotkeyAction, Shortcut) -> HotkeyManager.ApplyResult
    let suspend: () -> Void
    let resume: () -> Void
}

/// Click-to-record shortcut field for one hotkey. Idle shows the current
/// binding's keycaps (or "Disabled"); click → "Press keys…" and the next
/// valid combo is validated, registered, and saved live. ✕ disables. Errors
/// surface through the `error` binding (the parent row's description slot,
/// matching the launch-at-login pattern).
struct ShortcutRecorder: View {
    let action: HotkeyAction
    let shortcut: Shortcut
    let other: Shortcut
    let otherAction: HotkeyAction
    let otherName: String
    let actions: ShortcutActions
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
        actions.suspend()
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
        actions.resume()
    }

    private func cancel() { end(with: nil) }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape, Shortcut.carbonModifiers(from: event.modifierFlags) == 0 {
            cancel()
            return
        }
        guard let candidate = Shortcut.from(event: event) else { return } // unusable key — keep recording

        if let validationError = Shortcut.validate(candidate, against: other, otherAction: otherAction) {
            end(with: message(for: validationError))
            return
        }
        switch actions.apply(action, candidate) {
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
        var off = shortcut
        off.enabled = false
        _ = actions.apply(action, off)
    }

    private func message(for validationError: ShortcutError) -> String {
        switch validationError {
        case .noModifier: return "Add ⌘, ⌃, or ⌥."
        case .conflict: return "Already used by \(otherName)."
        case .systemReserved: return "That shortcut is reserved by macOS."
        }
    }
}
