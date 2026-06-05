import SwiftUI

/// Menu-bar dropdown — a native `NSMenu` (the scene uses `.menuBarExtraStyle(.menu)`).
/// `Text` items render as disabled status labels, `Button`s as standard menu items,
/// `Divider` as separators.
struct StatusItemView: View {
    @ObservedObject var state: AppState
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
        Button("Settings…", action: onOpenSettings)
            .keyboardShortcut(",")
        Button("Clear History…", action: onClearHistory)

        Divider()
        Button("Quit Recallyx") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
