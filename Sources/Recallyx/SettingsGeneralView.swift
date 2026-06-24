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
    let theme: SettingsTheme

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
                        action: .showHistory,
                        shortcut: settingsStore.settings.searchHistoryShortcut,
                        other: settingsStore.settings.transformSelectionShortcut,
                        otherAction: .transformSelection,
                        otherName: "Transform selection",
                        actions: shortcutActions,
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
                        action: .transformSelection,
                        shortcut: settingsStore.settings.transformSelectionShortcut,
                        other: settingsStore.settings.searchHistoryShortcut,
                        otherAction: .showHistory,
                        otherName: "Search & paste history",
                        actions: shortcutActions,
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
                    desc: "Oldest clips are evicted beyond this cap.",
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
