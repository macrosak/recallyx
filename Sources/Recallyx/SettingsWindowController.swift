import AppKit
import SwiftUI

/// Owns the Settings window. LSUIElement apps have no Dock-driven Preferences
/// path, so we drive the window manually from the menu-bar dropdown and from
/// first launch. The title bar is transparent + full-size content so the custom
/// header sits behind the native traffic lights, matching the design.
@MainActor
final class SettingsWindowController {
    private let settingsStore: SettingsStore
    private let clearHistory: () -> Void
    private let shortcutActions: ShortcutActions
    private var window: NSWindow?

    init(settingsStore: SettingsStore, clearHistory: @escaping () -> Void, shortcutActions: ShortcutActions) {
        self.settingsStore = settingsStore
        self.clearHistory = clearHistory
        self.shortcutActions = shortcutActions
    }

    func show(tab: SettingsTab = .general) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(settingsStore: settingsStore, clearHistory: clearHistory, shortcutActions: shortcutActions, initialTab: tab)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Recallyx Settings"
        // Close only: a fixed-size settings window, so minimize + zoom show
        // disabled (gray) — matching the design. (Dropping .resizable also drops
        // the zoom button's active state; .fullSizeContentView keeps the header
        // drawing up under the transparent titlebar.)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 740))
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
