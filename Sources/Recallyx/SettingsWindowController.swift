import AppKit
import SwiftUI
import RecallyxCore

/// Owns the Settings window. LSUIElement apps have no Dock-driven Preferences
/// path, so we drive the window manually from the menu-bar dropdown and from
/// first launch. The title bar is transparent + full-size content so the custom
/// header sits behind the native traffic lights, matching the design.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let clearHistory: () -> Void
    private let shortcutActions: ShortcutActions
    private let revealUsageJournal: () -> Void
    private let clearUsageJournal: () -> Void
    private let revealFileLog: () -> Void
    private let clearFileLog: () -> Void
    private var window: NSWindow?

    init(
        settingsStore: SettingsStore,
        clearHistory: @escaping () -> Void,
        shortcutActions: ShortcutActions,
        revealUsageJournal: @escaping () -> Void = {},
        clearUsageJournal: @escaping () -> Void = {},
        revealFileLog: @escaping () -> Void = {},
        clearFileLog: @escaping () -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.clearHistory = clearHistory
        self.shortcutActions = shortcutActions
        self.revealUsageJournal = revealUsageJournal
        self.clearUsageJournal = clearUsageJournal
        self.revealFileLog = revealFileLog
        self.clearFileLog = clearFileLog
        super.init()
    }

    /// Closing the Settings window isn't a termination path, so the debounced
    /// save could still be pending. Flush so any just-made edit reaches disk
    /// even if the app is killed (e.g. install.sh's killall) right after.
    func windowWillClose(_ notification: Notification) {
        settingsStore.flush()
    }

    func show(tab: SettingsTab = .general) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            settingsStore: settingsStore,
            clearHistory: clearHistory,
            shortcutActions: shortcutActions,
            revealUsageJournal: revealUsageJournal,
            clearUsageJournal: clearUsageJournal,
            revealFileLog: revealFileLog,
            clearFileLog: clearFileLog,
            initialTab: tab
        )
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
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
