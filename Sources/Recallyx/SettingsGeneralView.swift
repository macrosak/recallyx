import SwiftUI
import RecallyxCore

/// The General settings tab: Shortcuts, History, Startup, plus the cross-provider
/// Default-model picker. Per-provider key/URL config moved to the Providers tab.
struct SettingsGeneralView: View {
    @ObservedObject var settingsStore: SettingsStore
    let clearHistory: () -> Void
    let shortcutActions: ShortcutActions
    var revealUsageJournal: () -> Void = {}
    var clearUsageJournal: () -> Void = {}
    var revealFileLog: () -> Void = {}
    var clearFileLog: () -> Void = {}
    /// `iCloudSyncEnabled` as it was when the app launched (the store is built
    /// once from it). Compared against the live setting to show "Relaunch now".
    var iCloudSyncLaunchValue: Bool = false
    var relaunch: () -> Void = {}
    /// The shared sync observer — drives the "Last sync" status line. Nil in
    /// contexts that don't wire it (the row simply hides).
    var syncMonitor: SyncActivityMonitor?
    /// Whether CloudKit mirroring is actually running on this store (sync on +
    /// entitled + built with it). Gates the whole status row on/off.
    var syncActive: Bool = false
    /// Explicit "Sync now" kick — `store.refreshFromCloud(minInterval: 0)`.
    var syncNow: () -> Void = {}
    let theme: SettingsTheme

    /// True only when this build carries the iCloud entitlement (the team-signed
    /// Xcode build). The ad-hoc/DMG build lacks it, so its sync toggle is disabled
    /// with an explanatory caption — enabling it there would attach CloudKit
    /// mirroring and crash at launch, so the gate keeps it honestly off.
    private let syncEntitled = PersistenceController.processHasCloudKitEntitlement

    /// Whether the "Relaunch now" button should show next to the sync toggle:
    /// only once the live setting has drifted from the value the app launched
    /// with (toggling it back off hides the button again).
    static func relaunchButtonVisible(current: Bool, launchValue: Bool) -> Bool {
        current != launchValue
    }

    @State private var capText: String = ""
    @State private var launchError: String?
    @State private var searchShortcutError: String?
    @State private var transformShortcutError: String?

    var body: some View {
        VStack(spacing: 17) {
            defaultModelSection
            shortcutsSection
            historySection
            startupSection
        }
        .onAppear {
            capText = String(settingsStore.settings.retentionCap)
        }
    }

    // MARK: - Default model

    /// Cross-provider setting: the model AI steps use when they don't override
    /// it. Lists only enabled providers (`availableGroups(for:)`), plus the
    /// current value if it belongs to a now-unavailable provider so the Picker
    /// never renders blank.
    private var defaultModelSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Default model", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(label: "Default model", desc: "Used by AI steps without an override. Add providers in the Providers tab.", last: true, theme: theme) {
                    Picker("", selection: Binding(
                        get: { settingsStore.settings.defaultModel },
                        set: { settingsStore.settings.defaultModel = $0 }
                    )) {
                        ForEach(ModelCatalog.groupsPreservingSelection(
                            ModelCatalog.availableGroups(for: settingsStore.settings.providers),
                            selected: settingsStore.settings.defaultModel
                        )) { group in
                            Section(group.title) {
                                ForEach(group.models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Shortcuts", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(label: "Search & paste history", desc: searchShortcutError, theme: theme) {
                    ShortcutRecorder(
                        shortcut: settingsStore.settings.searchHistoryShortcut,
                        suspend: shortcutActions.suspend,
                        resume: shortcutActions.resume,
                        validate: { candidate in
                            Shortcut.validate(
                                candidate,
                                against: settingsStore.settings.transformSelectionShortcut,
                                otherAction: .transformSelection
                            ).map { ShortcutRecorder.message(for: $0, otherName: "Transform selection") }
                        },
                        apply: { shortcutActions.apply(.showHistory, $0) },
                        disableBinding: {
                            var off = settingsStore.settings.searchHistoryShortcut
                            off.enabled = false
                            _ = shortcutActions.apply(.showHistory, off)
                        },
                        error: $searchShortcutError,
                        theme: theme
                    )
                }
                SettingsRow(
                    label: "Transform selection",
                    desc: transformShortcutError ?? "Grab the current selection and open its actions.",
                    last: true,
                    theme: theme
                ) {
                    ShortcutRecorder(
                        shortcut: settingsStore.settings.transformSelectionShortcut,
                        suspend: shortcutActions.suspend,
                        resume: shortcutActions.resume,
                        validate: { candidate in
                            Shortcut.validate(
                                candidate,
                                against: settingsStore.settings.searchHistoryShortcut,
                                otherAction: .showHistory
                            ).map { ShortcutRecorder.message(for: $0, otherName: "Search & paste history") }
                        },
                        apply: { shortcutActions.apply(.transformSelection, $0) },
                        disableBinding: {
                            var off = settingsStore.settings.transformSelectionShortcut
                            off.enabled = false
                            _ = shortcutActions.apply(.transformSelection, off)
                        },
                        error: $transformShortcutError,
                        theme: theme
                    )
                }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "History", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(
                    label: "Keep most recent",
                    desc: settingsStore.settings.iCloudSyncEnabled
                        ? "Oldest clips are evicted beyond this cap. With iCloud sync on, eviction deletes across every synced device — the lowest cap in your fleet wins, and pinned clips are exempt."
                        : "Oldest clips are evicted beyond this cap.",
                    theme: theme
                ) {
                    SettingsField(text: $capText, mono: false, width: 64, theme: theme, onEditingEnded: commitCap)
                        .onChange(of: capText) { raw in
                            let digits = raw.filter(\.isNumber)
                            if digits != raw { capText = digits }
                        }
                    Text("items").font(.system(size: 12.5)).foregroundStyle(theme.textDim)
                }
                SettingsRow(
                    label: "Capture sensitive data",
                    desc: "Include password-manager & transient clips.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { settingsStore.settings.captureSensitive },
                        set: { settingsStore.settings.captureSensitive = $0 }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(theme.accent)
                }
                SettingsRow(
                    label: "Sync via iCloud (text)",
                    desc: syncEntitled
                        ? "Syncs your clipboard text and history across your Macs via your private iCloud. Images stay local for now. Takes effect after you quit and reopen Recallyx."
                        : "iCloud sync needs the team-signed build — this build has no iCloud entitlement. Build from source with the signed Xcode path (see the README's Building-from-source section); the ad-hoc/DMG build can't sync.",
                    theme: theme
                ) {
                    // Only in an entitled build, and only once the live value has
                    // drifted from what the app launched with — toggling it back
                    // hides the button again.
                    if syncEntitled && Self.relaunchButtonVisible(
                        current: settingsStore.settings.iCloudSyncEnabled,
                        launchValue: iCloudSyncLaunchValue
                    ) {
                        SettingsButton(title: "Relaunch now", theme: theme, action: relaunch)
                    }
                    Toggle("", isOn: Binding(
                        get: { settingsStore.settings.iCloudSyncEnabled },
                        set: { settingsStore.settings.iCloudSyncEnabled = $0 }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(theme.accent)
                    .disabled(!syncEntitled)
                }
                if syncActive, let syncMonitor {
                    SyncStatusRow(monitor: syncMonitor, syncNow: syncNow, theme: theme)
                }
                SettingsRow(
                    label: "Usage journal (local only)",
                    desc: "Records anonymous usage events to this Mac to help improve Recallyx. Never includes clipboard contents and is never sent anywhere.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { settingsStore.settings.usageJournalEnabled },
                        set: { settingsStore.settings.usageJournalEnabled = $0 }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(theme.accent)
                }
                SettingsRow(
                    label: "Usage journal data",
                    desc: "Inspect or delete the local journal file.",
                    theme: theme
                ) {
                    SettingsButton(title: "Reveal in Finder", theme: theme, action: revealUsageJournal)
                    SettingsButton(title: "Clear", kind: .danger, theme: theme, action: clearUsageJournal)
                }
                SettingsRow(
                    label: "Diagnostic log (local only)",
                    desc: "Keeps a rotating, content-free log on this Mac so a problem is captured for a bug report. Never includes clipboard contents and is never sent anywhere.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { settingsStore.settings.fileLogEnabled },
                        set: { settingsStore.settings.fileLogEnabled = $0 }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(theme.accent)
                }
                SettingsRow(
                    label: "Diagnostic log data",
                    desc: "Inspect or delete the local log file.",
                    theme: theme
                ) {
                    SettingsButton(title: "Reveal in Finder", theme: theme, action: revealFileLog)
                    SettingsButton(title: "Clear", kind: .danger, theme: theme, action: clearFileLog)
                }
                SettingsRow(
                    label: "Clear history",
                    desc: "Remove all stored clips and images.",
                    last: true,
                    theme: theme
                ) {
                    SettingsButton(title: "Clear…", kind: .danger, theme: theme, action: clearHistory)
                }
            }
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Startup", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(
                    label: "Launch at login",
                    desc: launchError ?? "Recallyx lives in the menu bar.",
                    last: true,
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { settingsStore.settings.launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(theme.accent)
                }
            }
        }
    }

    // MARK: - Actions

    /// Apply the cap only on commit (Return / focus loss), never per keystroke —
    /// an intermediate value like the "5" while typing "500" would immediately
    /// evict (and delete the image files of) almost the whole history.
    private func commitCap() {
        guard let value = Int(capText), value > 0 else {
            capText = String(settingsStore.settings.retentionCap)
            return
        }
        settingsStore.settings.retentionCap = value
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            settingsStore.settings.launchAtLogin = enabled
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
    }
}

/// The "Last sync" status line + a "Sync now" button, shown under the iCloud
/// toggle only when mirroring is actually running. Observes the shared monitor
/// so the line refreshes as export/import events land.
private struct SyncStatusRow: View {
    @ObservedObject var monitor: SyncActivityMonitor
    let syncNow: () -> Void
    let theme: SettingsTheme

    var body: some View {
        SettingsRow(
            label: "Sync status",
            desc: SyncStatusLine.text(
                lastExport: monitor.lastExportSuccess,
                lastImport: monitor.lastImportSuccess,
                lastError: monitor.lastError
            ) ?? "Waiting for the first sync…",
            theme: theme
        ) {
            SettingsButton(title: "Sync now", theme: theme, action: syncNow)
        }
    }
}
