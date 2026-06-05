import SwiftUI

/// Menu-bar dropdown — a native `NSMenu` (the scene uses `.menuBarExtraStyle(.menu)`).
/// `Text` items render as disabled status labels, `Button`s as standard menu items,
/// `Divider` as separators.
struct StatusItemView: View {
    @ObservedObject var state: AppState
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
        // The shortcuts mirror the global Carbon hotkeys (⌘⇧V / ⌃⇧V). As status
        // menu key equivalents they only fire while this menu is open, so there's
        // no double-trigger with the global registration.
        Button("Search history", action: onSearchHistory)
            .keyboardShortcut("v", modifiers: [.command, .shift])
        Button("Transform selection", action: onTransformSelection)
            .keyboardShortcut("v", modifiers: [.control, .shift])

        Divider()
        Button("Settings…", action: onOpenSettings)
            .keyboardShortcut(",")
        Button("Clear History…", action: onClearHistory)

        Divider()
        Button("Quit Recallyx") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
