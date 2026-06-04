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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching")
        // Launch wiring is filled in across later commits: history store,
        // clipboard watcher, hotkeys, panel, settings. The lazy-MenuBarExtra
        // lesson from AI Replace means all of this must live here, NOT on the
        // MenuBarExtra content's `.task`.
    }

    func openSettings() {
        // Wired up in commit 6 (Settings window).
        Log.info("openSettings (not yet wired)")
    }

    func clearHistory() {
        // Wired up in commit 6 (Settings / history store).
        Log.info("clearHistory (not yet wired)")
    }
}
