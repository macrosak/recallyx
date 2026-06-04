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
    private var hotkey: HotkeyManager?
    private var historyPanel: HistoryPanelController?

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

        let historyPanel = HistoryPanelController(
            itemsProvider: { [store] in store.items },
            imageURLResolver: { [store] in store.imageURL(for: $0) },
            onBuiltin: { [weak self] action, item, app in
                self?.runBuiltin(action, item: item, into: app) ?? true
            }
        )
        self.historyPanel = historyPanel

        hotkey = HotkeyManager { [weak self] action in
            switch action {
            case .showHistory: self?.historyPanel?.toggle()
            case .transformSelection: break // wired in the ⌃⇧V commit
            }
        }
    }

    /// Run a built-in action against a clip. Returns whether the panel should
    /// dismiss afterwards (true for everything except Delete, which keeps the
    /// panel open so the user can keep browsing).
    @discardableResult
    private func runBuiltin(_ action: BuiltinAction, item: HistoryItem, into app: NSRunningApplication?) -> Bool {
        switch action {
        case .paste:
            paste(item, into: app)
            return true
        case .copy:
            if let text = item.text { Paster.copyText(text) }
            watcher?.markSelfCopy(item.contentHash)
            state.flash(.success)
            return true
        case .delete:
            store.delete(item.id)
            return false
        case .copyFilePath:
            if let url = store.imageURL(for: item) { Paster.copyText(url.path) }
            state.flash(.success)
            return true
        case .revealInFinder:
            if let url = store.imageURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return true
        }
    }

    /// Paste a chosen history clip back into the source app, then bump it to the
    /// top. The watcher's self-write guard keeps this from creating a duplicate.
    private func paste(_ item: HistoryItem, into app: NSRunningApplication?) {
        watcher?.markSelfCopy(item.contentHash)
        store.bump(item.id)
        Task { @MainActor in
            switch item.kind {
            case .text:
                await Paster.pasteText(item.text ?? "", into: app)
            case .image:
                if let url = store.imageURL(for: item), let image = NSImage(contentsOf: url) {
                    await Paster.pasteImage(image, into: app)
                }
            }
            state.flash(.success)
        }
    }

    func openSettings() {
        // Wired up in commit 6 (Settings window).
        Log.info("openSettings (not yet wired)")
    }

    func clearHistory() {
        store.clear()
    }
}
