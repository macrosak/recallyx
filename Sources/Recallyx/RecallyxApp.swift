import Carbon.HIToolbox
import SwiftUI
import RecallyxCore

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
    // Opt-in, off-by-default, local-only usage journal. Honors RECALLYX_DATA_DIR
    // (like the history store) so debug runs write to the scratch dir.
    private lazy var journal = UsageJournal(
        enabled: settingsStore.settings.usageJournalEnabled,
        fileURL: ProcessInfo.processInfo.environment["RECALLYX_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("usage.jsonl") }
    )
    private var watcher: ClipboardWatcher?
    private var hotkey: HotkeyManager?
    private var historyPanel: HistoryPanelController?
    private var settingsWindow: SettingsWindowController?
    private var debugHooks: DebugHooks?
    private let notifier = Notifier()
    private let accessibility = AccessibilityClient()
    private lazy var actionRunner = ActionRunner(
        defaultModel: { [settingsStore] in settingsStore.settings.defaultModel },
        ollamaBaseURL: { [settingsStore] in settingsStore.settings.ollamaBaseURL },
        // Resolve a `custom:<id>:<model>` step to its endpoint: find the enabled
        // provider by id in the live settings list and hand the facade its base
        // URL + keychain account (the secret stays in the Keychain).
        customEndpoint: { [settingsStore] providerID in
            guard let provider = settingsStore.settings.providers.first(where: {
                $0.type == .openAICompatible && $0.enabled
                    && $0.id.uuidString.lowercased() == providerID.lowercased()
            }),
            let baseURL = provider.baseURL, !baseURL.isEmpty else { return nil }
            let account = provider.keychainAccount ?? ProviderConfig.customKeychainAccount(for: provider.id)
            return (baseURL: baseURL, keychainAccount: account)
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reflect the persisted preference into the on-disk log sink before the
        // first Log call so a disabled log never writes. Default is ON.
        FileLog.shared.enabled = settingsStore.settings.fileLogEnabled
        Log.info("applicationDidFinishLaunching")
        // The lazy-MenuBarExtra lesson from AI Replace means all launch wiring
        // must live here, NOT on the MenuBarExtra content's `.task`.

        // Diagnostic: what did the settings store load from disk at launch?
        let loadedActions = settingsStore.settings.actions
        Log.info("actions loaded (\(loadedActions.count)): [\(loadedActions.map(\.name).joined(separator: ", "))]")

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
            self?.journal.enabled = settings.usageJournalEnabled
            FileLog.shared.enabled = settings.fileLogEnabled
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
            ),
            revealUsageJournal: { [weak self] in self?.revealUsageJournal() },
            clearUsageJournal: { [weak self] in self?.journal.clear() },
            revealFileLog: { [weak self] in self?.revealFileLog() },
            clearFileLog: { Task { await FileLog.shared.clear() } }
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
            },
            onCopySelection: { [weak self] copied, sourceClip in
                self?.handleCopiedSelection(copied, fromClip: sourceClip)
            },
            log: { [weak self] event, fields in self?.journal.log(event, fields) }
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
                openSettings: { [weak self] tab in self?.openSettings(tab: tab) },
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

    /// Guards `handleTransformSelection` against re-entrancy. The visibility
    /// check is synchronous but the capture is async (the ⌘C fallback polls the
    /// pasteboard for up to ~500ms), so a fast second ⌃⇧V would otherwise pass
    /// the guard and double-capture + dismiss→reshow. Set before the capture
    /// Task, cleared when it ends.
    private var isTransforming = false

    /// Transform-selection hotkey (⌃⇧V default) — grab the current selection,
    /// push it to the top of history, and open the panel already on that clip's
    /// action menu (the AI-Replace replacement).
    private func handleTransformSelection() {
        if historyPanel?.isVisible == true { historyPanel?.dismiss(); return }
        guard !isTransforming else { return }
        guard accessibility.ensureTrustedOrPrompt() else { return }
        isTransforming = true

        Task { @MainActor in
            defer { isTransforming = false }
            let captured: (text: String, sourceApp: NSRunningApplication?)
            do {
                captured = try await captureSelectionWithFallback()
            } catch AccessibilityError.noSelection, AccessibilityError.readFailed, AccessibilityError.noFocusedElement {
                Log.info("transform: no selection")
                journal.log("transform_selection", ["captured": false])
                let combo = settingsStore.settings.transformSelectionShortcut.glyphs.joined()
                notifier.notify(body: "Select some text first, then press \(combo).")
                return
            } catch {
                Log.error("transform capture failed: \(error.localizedDescription)")
                journal.log("transform_selection", ["captured": false])
                notifier.notify(body: error.localizedDescription)
                return
            }

            journal.log("transform_selection", ["captured": true])
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
            let id = store.add(clip)
            Log.info("transform captured selection len=\(captured.text.count) — opening actions")
            historyPanel?.showOnTopActions(focusing: id)
        }
    }

    /// AX read first (instant where it works); Chromium/Gmail don't expose
    /// `kAXSelectedText`, so any read miss falls back to a synthesized ⌘C and
    /// the pasteboard. The fallback snapshots the user's clipboard, reads the
    /// selection, then restores it and `markSelfWrite()`s the restore so the
    /// watcher ignores it. The captured selection still reaches history via the
    /// `store.add` in `handleTransformSelection` — restoring the live clipboard
    /// is non-lossy.
    private func captureSelectionWithFallback() async throws -> (text: String, sourceApp: NSRunningApplication?) {
        do {
            return try accessibility.captureSelection()
        } catch AccessibilityError.noSelection, AccessibilityError.readFailed, AccessibilityError.noFocusedElement {
            Log.info("transform: AX selection read missed — trying ⌘C fallback")
            return try await accessibility.captureSelectionViaCopy(
                markSelfWrite: { [weak self] in self?.watcher?.markSelfWrite() }
            )
        }
    }

    /// The user copied a substring of the viewed clip in the detail pane (⌘C).
    /// Add it as a new text clip — inheriting the *viewed* clip's provenance, not
    /// "Recallyx" — and hand the stored item back so the panel can fold it into
    /// the open list while keeping the original clip selected.
    ///
    /// Returns nil (no clip added) for empty/whitespace-only selections. The text
    /// view already wrote the pasteboard, so `markSelfWrite()` first keeps the
    /// watcher's next tick from re-capturing the same content (dedupe is the
    /// backstop if the timing races).
    private func handleCopiedSelection(_ text: String, fromClip src: HistoryItem) -> HistoryItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        watcher?.markSelfWrite()
        let clip = CapturedClip(
            kind: .text, text: text, imageData: nil,
            preview: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280)),
            byteSize: text.utf8.count,
            sourceAppBundleID: src.sourceAppBundleID,
            sourceAppName: src.sourceAppName,
            sourceAppPath: src.sourceAppPath,
            contentHash: ContentHash.of(text: text), imageDimensions: nil
        )
        let id = store.add(clip)
        journal.log("copy_selection", ["length": text.count])
        Log.info("detail-pane copy captured len=\(text.count) — added as new clip")
        return store.items.first { $0.id == id }
    }

    /// Run a saved (or transient) action over a clip's text and paste the result
    /// at the cursor. The result re-enters history naturally via the watcher
    /// (it's new content, so it's NOT marked as a self-copy).
    func runAction(_ action: Action, item: HistoryItem, into app: NSRunningApplication?) {
        // Resolve the input up front: text clips thread their text; image clips
        // feed their PNG bytes to the runner's image path (first step = AI).
        var imageData: Data?
        if item.kind == .image {
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url) else {
                notifier.notify(body: "Couldn't read the image for this clip.")
                return
            }
            imageData = data
        } else if item.text == nil {
            notifier.notify(body: ActionError.imageNotSupported.localizedDescription)
            return
        }
        state.status = .working
        journal.log("action_run", actionRunFields(action, item: item))
        Task { @MainActor in
            do {
                let result: String
                if let imageData {
                    result = try await actionRunner.run(action, onImageData: imageData)
                } else {
                    result = try await actionRunner.run(action, on: item.text ?? "")
                }
                // An empty/whitespace-only result must NOT paste — doing so would
                // set the clipboard to "" and synth-⌘V over the user's current
                // selection, silently wiping it. Surface a no-op instead.
                guard !ActionRunner.isEmptyResult(result) else {
                    journal.log("action_error", ["name": action.name, "category": "emptyResult"])
                    Log.info("action produced no output — skipping paste")
                    state.flash(.error("no output"))
                    notifier.notify(body: "Action produced no output.")
                    return
                }
                await Paster.pasteText(result, into: app)
                state.flash(.success)
            } catch let ActionError.missingApiKey(provider) {
                journal.log("action_error", ["name": action.name, "category": "missingApiKey"])
                state.flash(.error("no key"))
                notifier.notify(body: "Set your \(provider.displayName) API key in Settings.", action: .openSettings)
            } catch OpenAIError.invalidApiKey {
                journal.log("action_error", ["name": action.name, "category": "invalidApiKey"])
                state.flash(.error("invalid key"))
                notifier.notify(body: "OpenAI rejected the API key (401). Update it in Settings.", action: .openSettings)
            } catch AnthropicError.invalidApiKey {
                journal.log("action_error", ["name": action.name, "category": "invalidApiKey"])
                state.flash(.error("invalid key"))
                notifier.notify(body: "Anthropic rejected the API key (401). Update it in Settings.", action: .openSettings)
            } catch GeminiError.invalidApiKey {
                journal.log("action_error", ["name": action.name, "category": "invalidApiKey"])
                state.flash(.error("invalid key"))
                notifier.notify(body: "Google Gemini rejected the API key (401). Update it in Settings.", action: .openSettings)
            } catch {
                // Category from the error TYPE only — never the raw message,
                // which can echo user text / script output.
                journal.log("action_error", ["name": action.name, "category": Self.errorCategory(error)])
                // Log the error CATEGORY, never the raw message — a failing
                // script step carries its stderr and an AI client carries the
                // API response body, both of which can echo the clip text. The
                // persistent file log must stay content-free. `state.lastError`
                // / the notification are transient in-memory/UI surfaces (not
                // persisted) so they keep the human-readable detail.
                Log.error("action failed: category=\(Self.errorCategory(error))")
                state.lastError = error.localizedDescription
                state.flash(.error("action failed"))
                notifier.notify(body: error.localizedDescription)
            }
        }
    }

    /// Build the non-sensitive `action_run` event fields. Never includes the
    /// clip contents — only the action name (local-only, so a user-named action
    /// is fine), its kind/step types, the resolved provider, the clip kind, and
    /// whether it was the one-off Custom… run.
    private func actionRunFields(_ action: Action, item: HistoryItem) -> [String: Any] {
        let stepTypes = action.steps.filter(\.enabled).map { $0.type.rawValue }
        let provider = resolvedProvider(for: action)
        return [
            "name": action.name,
            "kind": action.kindTag,
            "stepTypes": stepTypes,
            "provider": provider.map { $0 as Any } ?? NSNull(),
            "clipKind": item.kind.rawValue,
            "custom": action.name == "Custom",
        ]
    }

    /// The AI provider an action would use, or nil if it has no enabled AI step.
    /// Resolves the first enabled AI step's per-step model, falling back to the
    /// default model. Mirrors `AIProvider.provider(for:)`.
    private func resolvedProvider(for action: Action) -> String? {
        guard let aiStep = action.steps.first(where: { $0.enabled && $0.type == .ai }) else { return nil }
        let model = aiStep.model ?? settingsStore.settings.defaultModel
        switch AIProvider.provider(for: model) {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        case .gemini: return "gemini"
        case .ollama: return "ollama"
        case .apple: return "apple"
        case .openAICompatible: return "custom"
        }
    }

    /// Map an error to a short category string (from the error TYPE, never the
    /// raw message — messages can contain user text / script output).
    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case ActionError.imageNotSupported: return "imageNotSupported"
        case ActionError.scriptFirstOnImage: return "scriptFirstOnImage"
        case ActionError.missingApiKey: return "missingApiKey"
        case is ScriptError: return "script"
        case let urlError as URLError: return "network(\(urlError.code.rawValue))"
        case is OpenAIError, is AnthropicError, is OllamaError: return "ai"
        default: return "other"
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
        case .pasteAsKeystrokes:
            typeKeystrokes(item, into: app)
            return true
        case .copy:
            if let text = item.text {
                Paster.setClipboardText(text)
                watcher?.markSelfWrite()
            }
            state.flash(.success)
            return true
        case .pin:
            store.setPinned(item.id, true)
            return false
        case .unpin:
            store.setPinned(item.id, false)
            return false
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
                guard let url = store.imageURL(for: item),
                      let data = try? Data(contentsOf: url) else {
                    state.flash(.error("missing image"))
                    return
                }
                Paster.setClipboardImage(data: data)
            }
            watcher?.markSelfWrite()
            await Paster.activateAndPaste(sourceApp: app)
            state.flash(.success)
        }
    }

    /// Paste a text clip out **line by line** (the "Paste as keystrokes" action)
    /// instead of one multi-line ⌘V — dodges terminals' bracketed-paste collapse
    /// (Claude Code's `[Pasted text]`): each line is a single-line ⌘V and the
    /// newlines between them are real Return keystrokes. Text clips only; image
    /// clips never reach here (not in `BuiltinAction.entries(for: .image)`). The
    /// per-line pasteboard writes (and the final clipboard restore) are marked
    /// self-written so the watcher ignores them. Bumps the clip like a normal paste.
    private func typeKeystrokes(_ item: HistoryItem, into app: NSRunningApplication?) {
        guard let text = item.text else { return }
        guard Paster.isTypeable(text) else {
            state.flash(.error("clip too long to type"))
            notifier.notify(body: "Clip too long to type as keystrokes.")
            return
        }
        store.bump(item.id)
        journal.log("paste", ["via": "keystrokes", "clipKind": item.kind.rawValue])
        Task { @MainActor in
            await Paster.typeText(
                text,
                newlineKey: settingsStore.settings.pasteKeystrokeNewlineKey,
                markSelfWrite: { [weak self] in self?.watcher?.markSelfWrite() },
                into: app
            )
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

    /// Open Settings on a specific tab. Used by the debug command channel
    /// (`open-settings [general|providers|actions]`); the no-arg `openSettings()`
    /// (status menu / notification deep-links) stays on the default General tab.
    func openSettings(tab: SettingsTab) {
        settingsWindow?.show(tab: tab)
    }

    /// Reveal the usage-journal file in Finder. If it doesn't exist yet (journal
    /// never enabled, or just cleared), open the containing folder instead.
    private func revealUsageJournal() {
        let url = journal.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Reveal the diagnostic log file in Finder. If it doesn't exist yet (logging
    /// disabled, or just cleared), open the containing folder instead.
    private func revealFileLog() {
        let url = FileLog.shared.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
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
