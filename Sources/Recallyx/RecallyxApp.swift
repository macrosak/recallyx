import Carbon.HIToolbox
import SwiftUI

@main
struct RecallyxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusItemView(
                state: delegate.state,
                settingsStore: delegate.settingsStore,
                onSearchHistory: { delegate.searchHistory() },
                onTransformSelection: { delegate.transformSelection() },
                onOpenSettings: { delegate.openSettings() },
                onClearHistory: { delegate.clearHistory() }
            )
        } label: {
            MenuBarIcon(state: delegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Observes AppState so the menu-bar icon re-renders on every status change.
/// Separate view because the App body does not observe the AppDelegate.
///
/// Idle shows the Recallyx brand mark (a template image echoing the app icon);
/// the transient working/success/error states swap in an SF Symbol so the icon
/// still conveys feedback.
private struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.status == .idle {
            Image(nsImage: MenuBarIconImage.shared)
        } else {
            Image(systemName: state.status.iconSystemName)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let settingsStore = SettingsStore() // StatusItemView observes it for live key-equivalents
    // RECALLYX_DATA_DIR redirects history to a scratch dir for debug runs
    // (see DebugHooks.swift); settings/UserDefaults are NOT isolated.
    private lazy var store = HistoryStore(
        baseURL: ProcessInfo.processInfo.environment["RECALLYX_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) },
        cap: settingsStore.settings.retentionCap
    )
    private var watcher: ClipboardWatcher?
    private var hotkey: HotkeyManager?
    private var historyPanel: HistoryPanelController?
    private var settingsWindow: SettingsWindowController?
    private var debugHooks: DebugHooks?
    private let notifier = Notifier()
    private let accessibility = AccessibilityClient()
    private lazy var actionRunner = ActionRunner(defaultModel: { [settingsStore] in settingsStore.settings.defaultModel })

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching")
        // The lazy-MenuBarExtra lesson from AI Replace means all launch wiring
        // must live here, NOT on the MenuBarExtra content's `.task`.

        notifier.requestAuthorizationIfNeeded()
        state.historyCount = store.items.count
        store.onChange = { [weak self] in
            guard let self else { return }
            self.state.historyCount = self.store.items.count
        }

        // Reconcile launch-at-login with the persisted preference.
        applyLaunchAtLoginIfDrifted()

        // Push live settings changes into the stores.
        settingsStore.onChange = { [weak self] settings in
            self?.store.cap = settings.retentionCap
        }

        // The watcher reads the "Capture sensitive data" flag live from settings.
        let watcher = ClipboardWatcher(
            store: store,
            captureSensitive: { [settingsStore] in settingsStore.settings.captureSensitive }
        )
        watcher.start()
        self.watcher = watcher

        let settingsWindow = SettingsWindowController(
            settingsStore: settingsStore,
            clearHistory: { [weak self] in self?.clearHistory() },
            shortcutActions: ShortcutActions(
                apply: { [weak self] action, shortcut in
                    self?.applyShortcut(action, shortcut) ?? .failed(OSStatus(eventNotHandledErr))
                },
                suspend: { [weak self] in self?.suspendHotkeys() },
                resume: { [weak self] in self?.resumeHotkeys() }
            )
        )
        self.settingsWindow = settingsWindow

        let historyPanel = HistoryPanelController(
            itemsProvider: { [store] in store.items },
            actionsProvider: { [settingsStore] in settingsStore.settings.actions },
            defaultModelProvider: { [settingsStore] in settingsStore.settings.defaultModel },
            imageURLResolver: { [store] in store.imageURL(for: $0) },
            onBuiltin: { [weak self] action, item, app in
                self?.runBuiltin(action, item: item, into: app) ?? true
            },
            onRunAction: { [weak self] action, item, app in
                self?.runAction(action, item: item, into: app)
            }
        )
        self.historyPanel = historyPanel

        // Also open Settings when a notification's action asks for it.
        NotificationCenter.default.addObserver(forName: .openRecallyxSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }

        let hotkey = HotkeyManager { [weak self] action in
            switch action {
            case .showHistory: self?.historyPanel?.toggle()
            case .transformSelection: self?.handleTransformSelection()
            }
        }
        self.hotkey = hotkey
        registerAtLaunch(.showHistory, settingsStore.settings.searchHistoryShortcut)
        registerAtLaunch(.transformSelection, settingsStore.settings.transformSelectionShortcut)

        if DebugHooks.isEnabled {
            debugHooks = DebugHooks(
                panel: historyPanel,
                openSettings: { [weak self] in self?.openSettings() },
                historyCount: { [store] in store.items.count }
            )
        }
    }

    /// A saved combo can have been taken by another app since last run; the
    /// hotkey then silently doesn't work, so surface it in the status menu.
    private func registerAtLaunch(_ action: HotkeyAction, _ shortcut: Shortcut) {
        if case .failed(let status) = hotkey?.apply(action, shortcut) {
            state.lastError = "Couldn't register \(shortcut.glyphs.joined()) (\(status)) — change it in Settings."
        }
    }

    /// Single mutation point for hotkey changes: Carbon first, settings only
    /// on success — a failed registration never clobbers the persisted (and
    /// still live) binding.
    func applyShortcut(_ action: HotkeyAction, _ shortcut: Shortcut) -> HotkeyManager.ApplyResult {
        guard let hotkey else { return .failed(OSStatus(eventNotHandledErr)) }
        let result = hotkey.apply(action, shortcut)
        switch result {
        case .ok, .disabled:
            switch action {
            case .showHistory: settingsStore.settings.searchHistoryShortcut = shortcut
            case .transformSelection: settingsStore.settings.transformSelectionShortcut = shortcut
            }
        case .failed:
            break
        }
        return result
    }

    /// Recording in Settings needs the raw keyDowns — see HotkeyManager.suspend.
    func suspendHotkeys() {
        hotkey?.suspend()
    }

    func resumeHotkeys() {
        hotkey?.resume(
            searchHistory: settingsStore.settings.searchHistoryShortcut,
            transformSelection: settingsStore.settings.transformSelectionShortcut
        )
    }

    /// Transform-selection hotkey (⌃⇧V default) — grab the current selection,
    /// push it to the top of history, and open the panel already on that clip's
    /// action menu (the AI-Replace replacement).
    private func handleTransformSelection() {
        if historyPanel?.isVisible == true { historyPanel?.dismiss(); return }
        guard accessibility.ensureTrustedOrPrompt() else { return }

        Task { @MainActor in
            let captured: (text: String, sourceApp: NSRunningApplication?)
            do {
                captured = try await captureSelectionWithFallback()
            } catch AccessibilityError.noSelection, AccessibilityError.readFailed, AccessibilityError.noFocusedElement {
                Log.info("transform: no selection")
                let combo = settingsStore.settings.transformSelectionShortcut.glyphs.joined()
                notifier.notify(body: "Select some text first, then press \(combo).")
                return
            } catch {
                Log.error("transform capture failed: \(error.localizedDescription)")
                notifier.notify(body: error.localizedDescription)
                return
            }

            let app = captured.sourceApp
            let clip = CapturedClip(
                kind: .text, text: captured.text, imageData: nil,
                preview: String(captured.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280)),
                byteSize: captured.text.utf8.count,
                sourceAppBundleID: app?.bundleIdentifier,
                sourceAppName: app?.localizedName,
                sourceAppPath: app?.bundleURL?.path,
                contentHash: ContentHash.of(text: captured.text), imageDimensions: nil
            )
            store.add(clip)
            Log.info("transform captured selection len=\(captured.text.count) — opening actions")
            historyPanel?.showOnTopActions()
        }
    }

    /// AX read first (instant where it works); Chromium/Gmail don't expose
    /// `kAXSelectedText`, so any read miss falls back to a synthesized ⌘C and
    /// the pasteboard. The watcher's next tick sees that copy too and
    /// dedupe-bumps against the item added above — no duplicate.
    private func captureSelectionWithFallback() async throws -> (text: String, sourceApp: NSRunningApplication?) {
        do {
            return try accessibility.captureSelection()
        } catch AccessibilityError.noSelection, AccessibilityError.readFailed, AccessibilityError.noFocusedElement {
            Log.info("transform: AX selection read missed — trying ⌘C fallback")
            return try await accessibility.captureSelectionViaCopy()
        }
    }

    /// Run a saved (or transient) action over a clip's text and paste the result
    /// at the cursor. The result re-enters history naturally via the watcher
    /// (it's new content, so it's NOT marked as a self-copy).
    func runAction(_ action: Action, item: HistoryItem, into app: NSRunningApplication?) {
        guard item.kind == .text, let text = item.text else {
            notifier.notify(body: ActionError.imageNotSupported.localizedDescription)
            return
        }
        state.status = .working
        Task { @MainActor in
            do {
                let result = try await actionRunner.run(action, on: text)
                await Paster.pasteText(result, into: app)
                state.flash(.success)
            } catch ActionError.missingApiKey {
                state.flash(.error("no key"))
                notifier.notify(body: "Set your OpenAI API key in Settings.", action: .openSettings)
            } catch OpenAIError.invalidApiKey {
                state.flash(.error("invalid key"))
                notifier.notify(body: "OpenAI rejected the API key (401). Update it in Settings.", action: .openSettings)
            } catch {
                Log.error("action failed: \(error.localizedDescription)")
                state.lastError = error.localizedDescription
                state.flash(.error("action failed"))
                notifier.notify(body: error.localizedDescription)
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
            if let text = item.text {
                Paster.setClipboardText(text)
                watcher?.markSelfWrite()
            }
            state.flash(.success)
            return true
        case .delete:
            store.delete(item.id)
            return false
        case .copyFilePath:
            if let url = store.imageURL(for: item) { Paster.setClipboardText(url.path) }
            state.flash(.success)
            return true
        case .revealInFinder:
            if let url = store.imageURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return true
        case .openInPreview:
            if let url = store.imageURL(for: item) {
                let config = NSWorkspace.OpenConfiguration()
                if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                    NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: config)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            return true
        }
    }

    /// Paste a chosen history clip back into the source app, then bump it to the
    /// top. The pasteboard write is marked as self-written (by changeCount,
    /// after the write) so the watcher bumps rather than re-captures.
    private func paste(_ item: HistoryItem, into app: NSRunningApplication?) {
        store.bump(item.id)
        Task { @MainActor in
            switch item.kind {
            case .text:
                Paster.setClipboardText(item.text ?? "")
            case .image:
                guard let url = store.imageURL(for: item), let image = NSImage(contentsOf: url) else {
                    state.flash(.error("missing image"))
                    return
                }
                Paster.setClipboardImage(image)
            }
            watcher?.markSelfWrite()
            await Paster.activateAndPaste(sourceApp: app)
            state.flash(.success)
        }
    }

    /// ⌘⇧V from the menu — toggle the history panel (same as the global hotkey).
    func searchHistory() {
        historyPanel?.toggle()
    }

    /// ⌃⇧V from the menu — grab the selection and open its action menu.
    func transformSelection() {
        handleTransformSelection()
    }

    func openSettings() {
        settingsWindow?.show()
    }

    /// Clearing is irreversible (the image files are deleted too) — confirm
    /// first. Serves both the menu item and the Settings button.
    func clearHistory() {
        guard !store.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "All \(store.items.count) clips and their stored images will be deleted. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    /// Both stores debounce their writes (~250ms); flush so a quit right after
    /// a copy or settings change doesn't lose the last mutation.
    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        settingsStore.flush()
    }

    /// The system can silently disable us (user removed us from Login Items);
    /// the persisted preference wins — reconcile on every launch.
    private func applyLaunchAtLoginIfDrifted() {
        let want = settingsStore.settings.launchAtLogin
        guard LaunchAtLogin.isEnabled != want else { return }
        do {
            try LaunchAtLogin.set(want)
            Log.info("launch-at-login reconciled to \(want)")
        } catch {
            Log.error("launch-at-login reconcile failed: \(error.localizedDescription)")
        }
    }
}
