import SwiftUI

/// Menu-bar dropdown — a native `NSMenu` (the scene uses `.menuBarExtraStyle(.menu)`).
/// `Text` items render as disabled status labels, `Button`s as standard menu items,
/// `Divider` as separators.
struct StatusItemView: View {
    @ObservedObject var state: AppState
    // Observed (not plain Shortcut values) so a rebind in Settings re-renders
    // the menu — this view is built in the App body, which doesn't observe
    // the delegate.
    @ObservedObject var settingsStore: SettingsStore
    var onSearchHistory: () -> Void = {}
    var onTransformSelection: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onClearHistory: () -> Void = {}

    var body: some View {
        Text(state.status.menuLabel)
        Text("\(state.historyCount) clips in history")

        if !state.lastError.isEmpty {
            Divider()
            Text("Last error: \(state.lastError)")
        }

        Divider()
        // The shortcuts mirror the live global Carbon hotkeys. As status menu
        // key equivalents they only fire while this menu is open, so there's
        // no double-trigger with the global registration. A disabled hotkey
        // shows no key hint but stays clickable (nil keyboardShortcut).
        Button("Search history", action: onSearchHistory)
            .keyboardShortcut(settingsStore.settings.searchHistoryShortcut.keyboardShortcut)
        Button("Transform selection", action: onTransformSelection)
            .keyboardShortcut(settingsStore.settings.transformSelectionShortcut.keyboardShortcut)

        Divider()
        Button("Settings…", action: onOpenSettings)
            .keyboardShortcut(",")
        Button("Clear History…", action: onClearHistory)

        Divider()
        Button("Quit Recallyx") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
