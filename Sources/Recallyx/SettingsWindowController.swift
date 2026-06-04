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
    private var window: NSWindow?

    init(settingsStore: SettingsStore, clearHistory: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.clearHistory = clearHistory
    }

    func show(tab: SettingsTab = .general) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(settingsStore: settingsStore, clearHistory: clearHistory, initialTab: tab)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Recallyx Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 640))
        window.contentMinSize = NSSize(width: 600, height: 560)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
