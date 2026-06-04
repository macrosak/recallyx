import SwiftUI

@main
struct RecallyxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusItemView(
                state: delegate.state,
                onOpenSettings: { delegate.openSettings() },
                onClearHistory: { delegate.clearHistory() }
            )
        } label: {
            MenuBarIcon(state: delegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Observes AppState so the menu-bar icon re-renders on every status change.
/// Separate view because the App body does not observe the AppDelegate.
private struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.status.iconSystemName)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private let store = HistoryStore()
    private var watcher: ClipboardWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching")
        // The lazy-MenuBarExtra lesson from AI Replace means all launch wiring
        // must live here, NOT on the MenuBarExtra content's `.task`.

        state.historyCount = store.items.count
        store.onChange = { [weak self] in
            guard let self else { return }
            self.state.historyCount = self.store.items.count
        }

        // "Capture sensitive data" is off by default; wired to Settings in a
        // later commit.
        let watcher = ClipboardWatcher(store: store, captureSensitive: { false })
        watcher.start()
        self.watcher = watcher

        // Remaining wiring (hotkeys, history panel, settings window) lands in
        // later commits.
    }

    func openSettings() {
        // Wired up in commit 6 (Settings window).
        Log.info("openSettings (not yet wired)")
    }

    func clearHistory() {
        store.clear()
    }
}
