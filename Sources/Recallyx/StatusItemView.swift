import SwiftUI

/// Menu-bar dropdown: status line, history count, and the standard actions.
struct StatusItemView: View {
    @ObservedObject var state: AppState
    var onOpenSettings: () -> Void = {}
    var onClearHistory: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.status.menuLabel)
                .font(.headline)

            Text("\(state.historyCount) clips in history")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !state.lastError.isEmpty {
                Divider()
                Text("Last error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.lastError)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()
            Button("Settings…", action: onOpenSettings)
                .keyboardShortcut(",")
            Button("Clear history…", action: onClearHistory)
            Button("Quit Recallyx") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}
