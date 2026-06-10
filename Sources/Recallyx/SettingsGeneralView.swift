import SwiftUI

/// The General settings tab. Phase 1: Shortcuts, History, Startup. The OpenAI
/// section (API key + model) is added with the AI layer.
struct SettingsGeneralView: View {
    @ObservedObject var settingsStore: SettingsStore
    let clearHistory: () -> Void
    let theme: SettingsTheme

    @State private var capText: String = ""
    @State private var launchError: String?
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var testResult: KeyTestResult = .idle

    private let keychain = KeychainStore.openAIKey

    private enum KeyTestResult: Equatable {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        VStack(spacing: 17) {
            openAISection
            shortcutsSection
            historySection
            startupSection
        }
        .onAppear {
            capText = String(settingsStore.settings.retentionCap)
            apiKey = keychain.read() ?? ""
        }
    }

    // MARK: - OpenAI

    private var openAISection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "OpenAI", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(label: "API key", desc: apiKeyDesc, theme: theme) {
                    if showKey {
                        SettingsField(text: $apiKey, placeholder: "sk-…", mono: true, width: 150, theme: theme)
                    } else {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(width: 150)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.inputBg)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.inputBorder, lineWidth: 0.5)))
                    }
                    SettingsButton(title: showKey ? "Hide" : "Show", theme: theme) { showKey.toggle() }
                    SettingsButton(title: "Test", theme: theme) { Task { await testKey() } }
                    SettingsButton(title: "Save", kind: .primary, theme: theme) { persistKey() }
                }
                SettingsRow(label: "Default model", desc: "Used by AI steps without an override.", last: true, theme: theme) {
                    Picker("", selection: Binding(
                        get: { settingsStore.settings.defaultModel },
                        set: { settingsStore.settings.defaultModel = $0 }
                    )) {
                        ForEach(ModelCatalog.all, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
        }
    }

    private var apiKeyDesc: String {
        switch testResult {
        case .idle: return "Stored in your macOS Keychain."
        case .testing: return "Testing key against \(ModelCatalog.default)…"
        case .ok: return "✓ API key is valid."
        case .failed(let msg): return "✗ \(msg)"
        }
    }

    private func persistKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { _ = keychain.delete() } else { _ = keychain.write(trimmed) }
    }

    /// Tests the key as typed in the field, WITHOUT persisting it — saving is
    /// Save's job; testing a bad key must not overwrite a working one.
    private func testKey() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        testResult = .testing
        do {
            _ = try await OpenAIClient().complete(apiKey: trimmed, model: ModelCatalog.default, promptTemplate: "Reply with: ok", text: "")
            testResult = .ok
        } catch OpenAIError.emptyResponse {
            testResult = .ok
        } catch {
            testResult = .failed(error.localizedDescription)
        }
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
