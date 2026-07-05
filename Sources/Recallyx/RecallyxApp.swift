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
                syncMonitor: delegate.syncMonitor,
                syncActive: delegate.isCloudSyncActive,
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
        cap: settingsStore.settings.retentionCap,
        // Opt-in CloudKit mirroring, read once at launch. Toggling the setting
        // rebuilds the store only on the next launch (see the Settings caption).
        cloudSyncEnabled: settingsStore.settings.iCloudSyncEnabled
    )
    // Opt-in, off-by-default, local-only usage journal. Honors RECALLYX_DATA_DIR
    // (like the history store) so debug runs write to the scratch dir.
    private lazy var journal = UsageJournal(
        enabled: settingsStore.settings.usageJournalEnabled,
        fileURL: ProcessInfo.processInfo.environment["RECALLYX_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("usage.jsonl") }
    )
    /// The single CloudKit sync observer — drives the Settings + menu-bar "Last
    /// sync" status line. Observed by `StatusItemView` (built in the App body).
    let syncMonitor = SyncActivityMonitor()
    /// Whether CloudKit mirroring is actually running (sync on + entitled + built
    /// with it) — gates the menu-bar / Settings "Last sync" line.
    var isCloudSyncActive: Bool { store.isCloudSyncActive }
    private var watcher: ClipboardWatcher?
    /// Apple Vision OCR for image clips (capture-time + a one-time launch
    /// backfill), making screenshots searchable by their text.
    private lazy var ocrService = OCRService(store: store)
    private var hotkey: HotkeyManager?
    private var historyPanel: HistoryPanelController?
    private var settingsWindow: SettingsWindowController?
    private var debugHooks: DebugHooks?
    /// `iCloudSyncEnabled` as read at launch to build `store` above (the store
    /// is built once, so toggling the setting only takes effect after a
    /// relaunch). Settings compares the live value against this to decide
    /// whether to show the "Relaunch now" button.
    private var iCloudSyncLaunchValue = false
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
        // Capture the launch-time sync setting before `store` (lazy) is first
        // touched below — this is the value it was actually built with.
        iCloudSyncLaunchValue = settingsStore.settings.iCloudSyncEnabled
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
            // Re-register per-action hotkeys on any settings change (a rebind,
            // an added/deleted action, or a shortcut cleared). Dropping the prior
            // set first releases stale combos; the recorder itself already
            // registered its own edit, so re-applying is idempotent.
            self?.hotkey?.applyAllActions(settings.actionShortcuts)
        }

        // The watcher reads the "Capture sensitive data" flag live from settings.
        // On each fresh image capture it hands the id + PNG to OCR so screenshots
        // become searchable by their text.
        let watcher = ClipboardWatcher(
            store: store,
            captureSensitive: { [settingsStore] in settingsStore.settings.captureSensitive },
            onImageCaptured: { [weak self] id, png in self?.ocrService.recognizeOnCapture(id: id, png: png) }
        )
        watcher.start()
        self.watcher = watcher

        // One-time, throttled OCR backfill of image clips captured before this
        // feature (or from earlier launches that hadn't finished). Runs serially
        // in the background so it doesn't spike CPU at login; each result saves,
        // so a relaunch just continues with whatever's left.
        ocrService.startBackfill()

        let settingsWindow = SettingsWindowController(
            settingsStore: settingsStore,
            clearHistory: { [weak self] in self?.clearHistory() },
            shortcutActions: ShortcutActions(
                apply: { [weak self] action, shortcut in
                    self?.applyShortcut(action, shortcut) ?? .failed(OSStatus(eventNotHandledErr))
                },
                applyAction: { [weak self] token, shortcut in
                    self?.applyActionShortcut(token, shortcut) ?? .failed(OSStatus(eventNotHandledErr))
                },
                suspend: { [weak self] in self?.suspendHotkeys() },
                resume: { [weak self] in self?.resumeHotkeys() }
            ),
            revealUsageJournal: { [weak self] in self?.revealUsageJournal() },
            clearUsageJournal: { [weak self] in self?.journal.clear() },
            revealFileLog: { [weak self] in self?.revealFileLog() },
            clearFileLog: { Task { await FileLog.shared.clear() } },
            iCloudSyncLaunchValue: iCloudSyncLaunchValue,
            relaunch: { [weak self] in self?.relaunch() },
            syncMonitor: syncMonitor,
            syncActive: store.isCloudSyncActive,
            // Explicit "Sync now" kick — no throttle (minInterval 0), unlike the
            // 45s-throttled ⌘⇧V panel-open kick.
            syncNow: { [weak self] in self?.store.refreshFromCloud(minInterval: 0) }
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
            log: { [weak self] event, fields in self?.journal.log(event, fields) },
            // Throttled CloudKit pull on panel open — no-op unless sync is on,
            // entitled, and it's been a while (≥ 45s) since the last kick, so the
            // frequent ⌘⇧V opens never thrash the store.
            onRefreshSync: { [weak self] in self?.store.refreshFromCloud(minInterval: 45) }
        )
        self.historyPanel = historyPanel

        // Also open Settings when a notification's action asks for it.
        NotificationCenter.default.addObserver(forName: .openRecallyxSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }

        let hotkey = HotkeyManager(
            onTrigger: { [weak self] action in
                switch action {
                case .showHistory: self?.historyPanel?.toggle()
                case .transformSelection: self?.handleTransformSelection()
                }
            },
            onActionTrigger: { [weak self] token in
                self?.handleActionHotkey(token)
            }
        )
        self.hotkey = hotkey
        registerAtLaunch(.showHistory, settingsStore.settings.searchHistoryShortcut)
        registerAtLaunch(.transformSelection, settingsStore.settings.transformSelectionShortcut)
        // Drop any stale binding for an action that no longer exists, then
        // register every per-action hotkey.
        pruneOrphanActionShortcuts()
        hotkey.applyAllActions(settingsStore.settings.actionShortcuts)

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

    /// Single mutation point for a per-action hotkey change: Carbon first,
    /// settings only on success (mirrors `applyShortcut`). A cleared/disabled
    /// binding removes the settings entry so no stale hotkey lingers.
    func applyActionShortcut(_ token: String, _ shortcut: Shortcut) -> HotkeyManager.ApplyResult {
        guard let hotkey else { return .failed(OSStatus(eventNotHandledErr)) }
        let result = hotkey.applyAction(token: token, shortcut)
        switch result {
        case .ok:
            settingsStore.settings.actionShortcuts[token] = shortcut
        case .disabled:
            settingsStore.settings.actionShortcuts[token] = nil
        case .failed:
            break
        }
        return result
    }

    /// Drop `actionShortcuts` entries whose action no longer exists (e.g. an
    /// action deleted in a build without this feature, or an out-of-band edit).
    private func pruneOrphanActionShortcuts() {
        let valid = Set(settingsStore.settings.actions.map { $0.id.uuidString })
        let orphans = settingsStore.settings.actionShortcuts.keys.filter { !valid.contains($0) }
        guard !orphans.isEmpty else { return }
        for token in orphans { settingsStore.settings.actionShortcuts[token] = nil }
        Log.info("pruned \(orphans.count) orphan action shortcut(s)")
    }

    /// Recording in Settings needs the raw keyDowns — see HotkeyManager.suspend.
    func suspendHotkeys() {
        hotkey?.suspend()
    }

    func resumeHotkeys() {
        hotkey?.resume(
            searchHistory: settingsStore.settings.searchHistoryShortcut,
            transformSelection: settingsStore.settings.transformSelectionShortcut,
            actionShortcuts: settingsStore.settings.actionShortcuts
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
            let combo = settingsStore.settings.transformSelectionShortcut.glyphs.joined()
            guard let (id, _) = await captureSelectionForTransform(emptyCombo: combo) else { return }
            Log.info("transform captured selection — opening actions")
            historyPanel?.showOnTopActions(focusing: id)
        }
    }

    /// A per-action global hotkey fired: find the bound action, grab the current
    /// selection (exactly the ⌃⇧V capture path), push it to history, and run the
    /// action on it in place — pasting the result back. No panel appears; that's
    /// the point (one keystroke instead of ⌃⇧V → menu → pick).
    private func handleActionHotkey(_ token: String) {
        guard let action = settingsStore.settings.actions.first(where: { $0.id.uuidString == token }) else {
            Log.info("action hotkey fired for unknown token — ignoring")
            return
        }
        guard !isTransforming else { return }
        guard accessibility.ensureTrustedOrPrompt() else { return }
        isTransforming = true

        Task { @MainActor in
            defer { isTransforming = false }
            let combo = (settingsStore.settings.actionShortcuts[token] ?? .transformSelectionDefault).glyphs.joined()
            guard let (id, app) = await captureSelectionForTransform(emptyCombo: combo) else { return }
            guard let item = store.items.first(where: { $0.id == id }) else { return }
            // An action that declares `{{INPUT:Label}}` needs a value the hotkey
            // can't supply — open the panel on that action's input prompt (v1
            // choice) instead of running silently with the raw token.
            if !ActionInputs.placeholders(in: action).isEmpty {
                Log.info("action hotkey '\(action.name)' needs input — opening panel prompt")
                historyPanel?.showInputPrompt(for: action, focusing: id)
                return
            }
            Log.info("action hotkey '\(action.name)' captured selection — running")
            runAction(action, item: item, into: app)
        }
    }

    /// Grab the current selection (AX read, then synth-⌘C fallback), push it to
    /// the top of history, and return the stored id + source app. Returns nil
    /// when nothing was selected or capture failed — already journaled + notified
    /// (the notification names `emptyCombo`). Shared by ⌃⇧V and per-action hotkeys.
    private func captureSelectionForTransform(emptyCombo: String) async -> (id: UUID, app: NSRunningApplication?)? {
        let captured: (text: String, sourceApp: NSRunningApplication?)
        do {
            captured = try await captureSelectionWithFallback()
        } catch AccessibilityError.noSelection, AccessibilityError.readFailed, AccessibilityError.noFocusedElement {
            Log.info("transform: no selection")
            journal.log("transform_selection", ["captured": false])
            notifier.notify(body: "Select some text first, then press \(emptyCombo).")
            return nil
        } catch {
            Log.error("transform capture failed: \(error.localizedDescription)")
            journal.log("transform_selection", ["captured": false])
            notifier.notify(body: error.localizedDescription)
            return nil
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
            contentHash: ContentHash.of(text: captured.text), imageDimensions: nil,
            sourceDeviceName: DeviceOrigin.name, sourceDeviceType: DeviceOrigin.type
        )
        let id = store.add(clip)
        Log.info("transform captured selection len=\(captured.text.count)")
        return (id, app)
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
            contentHash: ContentHash.of(text: text), imageDimensions: nil,
            sourceDeviceName: DeviceOrigin.name, sourceDeviceType: DeviceOrigin.type
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
                Paster.setClipboardText(result)
                guard ensurePasteTrusted() else { return }
                await Paster.activateAndPaste(sourceApp: app)
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
        case .pasteAsLines:
            typeLines(item, into: app)
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

    /// Gate a synthesized-⌘V paste on Accessibility permission. Returns true when
    /// the app is trusted (caller proceeds to synth the paste). When untrusted it
    /// prompts once per session (the modal, via `ensureTrustedOrPrompt`) AND posts a
    /// notification every time so repeated attempts still surface, then returns
    /// false. Callers MUST have already written the clip to the clipboard so a
    /// manual ⌘V is the working fallback.
    @discardableResult
    private func ensurePasteTrusted() -> Bool {
        if accessibility.ensureTrustedOrPrompt() { return true }
        state.flash(.error("grant Accessibility"))
        notifier.notify(
            body: "Copied to the clipboard. Grant Accessibility in Settings to auto-paste, then press ⌘V.",
            action: .openAccessibilitySettings
        )
        return false
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
            guard ensurePasteTrusted() else { return }
            await Paster.activateAndPaste(sourceApp: app)
            state.flash(.success)
        }
    }

    /// Paste a text clip out **line by line** (the "Paste as lines" action)
    /// instead of one multi-line ⌘V — dodges terminals' bracketed-paste collapse
    /// (Claude Code's `[Pasted text]`): each line is a single-line ⌘V and the
    /// newlines between them are real ⌥Return keystrokes. Text clips only; image
    /// clips never reach here (not in `BuiltinAction.entries(for: .image)`). The
    /// per-line pasteboard writes (and the final clipboard restore) are marked
    /// self-written so the watcher ignores them. Bumps the clip like a normal paste.
    private func typeLines(_ item: HistoryItem, into app: NSRunningApplication?) {
        guard let text = item.text else {
            Log.info("typeLines skipped: clip has no text (kind=\(item.kind.rawValue))")
            return
        }
        guard Paster.isTypeable(text) else {
            Log.info("typeLines skipped: not typeable chars=\(text.count) (empty/whitespace or over \(Paster.maxTypeableLength))")
            state.flash(.error("clip too long to paste as lines"))
            notifier.notify(body: "Clip too long to paste as lines.")
            return
        }
        Log.info("typeLines invoked chars=\(text.count) sourceApp=\(app?.bundleIdentifier ?? "nil")")
        store.bump(item.id)
        journal.log("paste", ["via": "lines", "clipKind": item.kind.rawValue])
        guard accessibility.isTrusted() else {
            // Line-by-line paste can't degrade mid-stream (typeText restores the
            // clipboard), so leave the whole clip on the pasteboard for a manual ⌘V.
            Paster.setClipboardText(text)
            watcher?.markSelfWrite()
            _ = ensurePasteTrusted()   // prompt + notify (isTrusted already false)
            return
        }
        Task { @MainActor in
            await Paster.typeText(
                text,
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
        flushPendingState()
    }

    private func flushPendingState() {
        store.flush()
        settingsStore.flush()
    }

    /// The Settings "Relaunch now" button — some settings (like `iCloudSyncEnabled`)
    /// are only read once at launch to build the stores, so flipping them needs a
    /// relaunch to take effect. Flushes pending state (same as quitting normally),
    /// then respawns the app bundle and terminates this process.
    ///
    /// In the debug/`swift run` case there's no `.app` bundle to respawn — just
    /// terminate, matching a manual quit-and-relaunch-from-source workflow.
    func relaunch() {
        flushPendingState()
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            Log.info("relaunch: no .app bundle (debug run) — terminating without respawn")
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            Log.error("relaunch: failed to spawn a new instance: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
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
