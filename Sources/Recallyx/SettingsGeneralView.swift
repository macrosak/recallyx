import SwiftUI

/// The General settings tab. Phase 1: Shortcuts, History, Startup. The OpenAI
/// section (API key + model) is added with the AI layer.
struct SettingsGeneralView: View {
    @ObservedObject var settingsStore: SettingsStore
    let clearHistory: () -> Void
    let theme: SettingsTheme

    @State private var capText: String = ""
    @State private var launchError: String?

    var body: some View {
        VStack(spacing: 17) {
            shortcutsSection
            historySection
            startupSection
        }
        .onAppear { capText = String(settingsStore.settings.retentionCap) }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Shortcuts", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(label: "Search & paste history", theme: theme) {
                    ShortcutChips(keys: ["⌘", "⇧", "V"], theme: theme)
                }
                SettingsRow(
                    label: "Transform selection",
                    desc: "Grab the current selection and open its actions.",
                    last: true,
                    theme: theme
                ) {
                    ShortcutChips(keys: ["⌃", "⇧", "V"], theme: theme)
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
                    SettingsField(text: $capText, mono: false, width: 64, theme: theme)
                        .onChange(of: capText) { commitCap($0) }
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

    private func commitCap(_ raw: String) {
        let digits = raw.filter(\.isNumber)
        if digits != raw { capText = digits }
        guard let value = Int(digits), value > 0 else { return }
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
