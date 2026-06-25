import SwiftUI
import RecallyxCore

/// The Providers settings tab: an explicit, user-managed list of AI providers.
/// Left = a native sidebar `List` (Finder-style selection + whole-row drag
/// reorder via `.onMove`) with add/remove controls; right = a per-provider
/// editor in the existing Settings card chrome. An enabled provider's models
/// appear in the Default-model + per-step pickers.
struct SettingsProvidersView: View {
    @ObservedObject var settingsStore: SettingsStore
    let theme: SettingsTheme

    @State private var selectedID: UUID?
    /// Bumped on any keychain write so the editor's Test/desc state refreshes.
    @State private var keychainRevision = 0

    private var providers: [ProviderConfig] { settingsStore.settings.providers }

    var body: some View {
        HStack(spacing: 0) {
            providerList
                .frame(width: 240)
                .overlay(alignment: .trailing) { Rectangle().fill(theme.cardBorder).frame(width: 0.5) }
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 460)
        .onAppear { if selectedID == nil { selectedID = providers.first?.id } }
    }

    // MARK: - Provider list (left, native sidebar)

    private var providerList: some View {
        VStack(spacing: 0) {
            // Native sidebar List: selection + whole-row drag-reorder, no custom
            // highlight overlay (a custom pill intercepts center hit-testing so
            // only the row edges drag — keep selection native).
            List(selection: $selectedID) {
                ForEach(providers) { provider in
                    ProviderRow(provider: provider)
                        .tag(provider.id)
                }
                .onMove(perform: moveProviders)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack(spacing: 2) {
                addMenu
                toolbarButton("minus") { deleteSelected() }
                Spacer()
            }
            .padding(8)
            .overlay(alignment: .top) { Rectangle().fill(theme.cardBorder).frame(height: 0.5) }
        }
        .background(theme.isDark ? Color(white: 0, opacity: 0.12) : Color(white: 0, opacity: 0.02))
    }

    private var addMenu: some View {
        Menu {
            ForEach(ProviderType.allCases, id: \.self) { type in
                Button(type.defaultDisplayName) { addProvider(type) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textDim)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 22)
        .help("Add a provider")
    }

    private func toolbarButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textDim)
                .frame(width: 24, height: 22)
                // Whole frame clickable (a thin glyph otherwise only hit-tests its
                // opaque pixels — the action-delete "can't click minus" lesson).
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A single sidebar row: type glyph + display name + a faint type/disabled
    /// hint. Only row content — no toggle/overlay — so the whole row drags.
    private struct ProviderRow: View {
        let provider: ProviderConfig
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: glyph(for: provider.type))
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(provider.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !provider.enabled {
                    Text("Off")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - Editor (right)

    @ViewBuilder
    private var editor: some View {
        if let binding = selectedBinding {
            ScrollView {
                ProviderEditor(
                    provider: binding,
                    theme: theme,
                    keychainRevision: $keychainRevision
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            // Re-key on selection so per-provider editor @State (key field etc.)
            // resets when switching providers.
            .id(binding.wrappedValue.id)
        } else {
            VStack {
                Spacer()
                Text("No providers — add one with +.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textDim)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Mutations

    private var selectedBinding: Binding<ProviderConfig>? {
        guard let id = selectedID, providers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { settingsStore.settings.providers.first { $0.id == id } ?? ProviderConfig(type: .openai) },
            set: { newValue in
                if let i = settingsStore.settings.providers.firstIndex(where: { $0.id == id }) {
                    settingsStore.settings.providers[i] = newValue
                }
            }
        )
    }

    private func addProvider(_ type: ProviderType) {
        var config = ProviderConfig(type: type)
        switch type {
        case .ollama:
            config.baseURL = settingsStore.settings.ollamaBaseURL
        case .openai, .anthropic, .gemini:
            config.keychainAccount = type.builtinKeychainAccount
        case .openAICompatible:
            config.keychainAccount = ProviderConfig.customKeychainAccount(for: config.id)
        case .apple:
            break
        }
        settingsStore.settings.providers.append(config)
        selectedID = config.id
        // Structural edit — persist immediately (a kill can outrun the debounce).
        settingsStore.flush()
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let idx = settingsStore.settings.providers.firstIndex(where: { $0.id == id }) else { return }
        let removed = settingsStore.settings.providers[idx]
        // A removed custom provider's key has no other owner — clean it up.
        if removed.type == .openAICompatible, let account = removed.keychainAccount {
            _ = KeychainStore.custom(account: account).delete()
        }
        settingsStore.settings.providers.remove(at: idx)
        selectedID = SettingsProvidersView.neighborSelection(in: settingsStore.settings.providers, removedIndex: idx)
        settingsStore.flush()
    }

    /// Which provider to select after removing the one at `removedIndex`. Pure.
    static func neighborSelection(in providers: [ProviderConfig], removedIndex: Int) -> UUID? {
        guard !providers.isEmpty else { return nil }
        return providers[min(removedIndex, providers.count - 1)].id
    }

    private func moveProviders(from source: IndexSet, to destination: Int) {
        var list = settingsStore.settings.providers
        list.move(fromOffsets: source, toOffset: destination)
        settingsStore.settings.providers = list
        settingsStore.flush()
    }
}

/// Per-type glyph for a provider row / editor header.
private func glyph(for type: ProviderType) -> String {
    switch type {
    case .openai: return "bolt.horizontal.circle"
    case .anthropic: return "a.circle"
    case .gemini: return "sparkles"
    case .ollama: return "desktopcomputer"
    case .apple: return "apple.logo"
    case .openAICompatible: return "server.rack"
    }
}

/// The right-hand editor for one provider. Per-type: cloud = key + Show/Test/Save;
/// Ollama = base URL; Apple = read-only; custom = name + URL + key + model list.
struct ProviderEditor: View {
    @Binding var provider: ProviderConfig
    let theme: SettingsTheme
    @Binding var keychainRevision: Int

    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var testResult: KeyTestResult = .idle
    @State private var newModel: String = ""

    enum KeyTestResult: Equatable { case idle, testing, ok, failed(String) }

    private var keychain: KeychainStore? {
        switch provider.type {
        case .openai: return .openAIKey
        case .anthropic: return .anthropicKey
        case .gemini: return .geminiKey
        case .openAICompatible:
            let account = provider.keychainAccount ?? ProviderConfig.customKeychainAccount(for: provider.id)
            return KeychainStore.custom(account: account)
        case .ollama, .apple: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            switch provider.type {
            case .openai, .anthropic, .gemini:
                cloudKeySection
            case .ollama:
                ollamaSection
            case .apple:
                appleSection
            case .openAICompatible:
                customSection
            }
        }
        .onAppear { apiKey = keychain?.read() ?? "" }
    }

    // MARK: Header (icon + enable toggle + name for custom)

    private var headerSection: some View {
        VStack(spacing: 0) {
            SettingsCard(theme: theme) {
                SettingsRow(label: provider.displayName, desc: provider.type.defaultDisplayName, theme: theme) {
                    Image(systemName: glyph(for: provider.type))
                        .font(.system(size: 18))
                        .foregroundStyle(theme.accent)
                        .frame(width: 30)
                }
                SettingsRow(label: "Enabled", desc: "Show this provider's models in the pickers.", last: provider.type != .openAICompatible, theme: theme) {
                    Toggle("", isOn: $provider.enabled)
                        .toggleStyle(.switch).labelsHidden().tint(theme.accent)
                }
                if provider.type == .openAICompatible {
                    SettingsRow(label: "Name", desc: "Shown as the picker group title.", last: true, theme: theme) {
                        SettingsField(text: $provider.displayName, placeholder: "Custom provider", width: 180, theme: theme)
                    }
                }
            }
        }
    }

    // MARK: Cloud (OpenAI / Anthropic / Gemini)

    private var cloudKeySection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "API key", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(label: "API key", desc: keyDesc, last: true, theme: theme) {
                    keyField(placeholder: keyPlaceholder)
                    SettingsButton(title: showKey ? "Hide" : "Show", theme: theme) { showKey.toggle() }
                    SettingsButton(title: "Test", theme: theme) { Task { await testKey() } }
                    SettingsButton(title: "Save", kind: .primary, theme: theme) { persistKey() }
                }
            }
        }
    }

    // MARK: Ollama

    private var ollamaSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Server", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(
                    label: "Server URL",
                    desc: "Local Ollama server for ollama:… models. No API key needed.",
                    last: true,
                    theme: theme
                ) {
                    SettingsField(
                        text: Binding(
                            get: { provider.baseURL ?? AppSettings.defaultOllamaBaseURL },
                            set: { provider.baseURL = $0 }
                        ),
                        placeholder: AppSettings.defaultOllamaBaseURL,
                        mono: true, width: 220, theme: theme
                    )
                }
            }
        }
    }

    // MARK: Apple

    private var appleSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "On-device", theme: theme)
            SettingsCard(theme: theme) {
                SettingsRow(
                    label: "Apple Intelligence",
                    desc: AppleClient.isAvailable
                        ? "On-device, no configuration. Runs locally; text-only."
                        : "Requires macOS 26+ with Apple Intelligence enabled and the model downloaded.",
                    last: true,
                    theme: theme
                ) {
                    Image(systemName: AppleClient.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(AppleClient.isAvailable ? theme.accent : theme.bad)
                }
            }
        }
    }

    // MARK: Custom (OpenAI-compatible)

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                SectionLabel(text: "Endpoint", theme: theme)
                SettingsCard(theme: theme) {
                    SettingsRow(label: "Base URL", desc: "OpenAI-compatible endpoint, e.g. https://api.groq.com/openai/v1", theme: theme) {
                        SettingsField(
                            text: Binding(
                                get: { provider.baseURL ?? "" },
                                set: { provider.baseURL = $0 }
                            ),
                            placeholder: "https://…/v1", mono: true, width: 240, theme: theme
                        )
                    }
                    SettingsRow(label: "API key", desc: keyDesc, last: true, theme: theme) {
                        keyField(placeholder: "key…")
                        SettingsButton(title: showKey ? "Hide" : "Show", theme: theme) { showKey.toggle() }
                        SettingsButton(title: "Test", theme: theme) { Task { await testKey() } }
                        SettingsButton(title: "Save", kind: .primary, theme: theme) { persistKey() }
                    }
                }
            }
            modelListSection
        }
    }

    private var modelListSection: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Models", theme: theme)
            SettingsCard(theme: theme) {
                ForEach(Array((provider.models ?? []).enumerated()), id: \.offset) { idx, model in
                    SettingsRow(label: model, theme: theme) {
                        SettingsButton(title: "Remove", kind: .danger, theme: theme) { removeModel(at: idx) }
                    }
                }
                SettingsRow(label: "Add model", desc: "Model id this endpoint serves, e.g. llama-3.1-70b.", last: true, theme: theme) {
                    SettingsField(text: $newModel, placeholder: "model id", mono: true, width: 160, theme: theme, onEditingEnded: addModel)
                    SettingsButton(title: "Add", theme: theme, action: addModel)
                }
            }
        }
    }

    // MARK: Shared key field

    @ViewBuilder
    private func keyField(placeholder: String) -> some View {
        if showKey {
            SettingsField(text: $apiKey, placeholder: placeholder, mono: true, width: 150, theme: theme)
        } else {
            SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(width: 150)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.inputBg)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.inputBorder, lineWidth: 0.5)))
        }
    }

    private var keyPlaceholder: String {
        switch provider.type {
        case .anthropic: return "sk-ant-…"
        case .gemini: return "AIza…"
        default: return "sk-…"
        }
    }

    private var keyDesc: String {
        switch testResult {
        case .idle: return "Stored in your macOS Keychain."
        case .testing: return "Testing key…"
        case .ok: return "✓ API key is valid."
        case .failed(let msg): return "✗ \(msg)"
        }
    }

    // MARK: Actions

    private func persistKey() {
        guard let keychain else { return }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { _ = keychain.delete() } else { _ = keychain.write(trimmed) }
        // Make sure the config records the account it saved under (custom).
        if provider.type == .openAICompatible, provider.keychainAccount == nil {
            provider.keychainAccount = keychain.account
        }
        keychainRevision += 1
    }

    /// Tests the key as typed WITHOUT persisting it. Cloud providers hit their
    /// cheapest model; a custom endpoint hits its first model at its base URL.
    private func testKey() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        testResult = .testing
        do {
            switch provider.type {
            case .openai:
                _ = try await OpenAIClient().complete(apiKey: trimmed, model: ModelCatalog.default, promptTemplate: "Reply with: ok", text: "")
            case .anthropic:
                _ = try await AnthropicClient().complete(apiKey: trimmed, model: ModelCatalog.anthropic.first ?? "claude-haiku-4-5", promptTemplate: "Reply with: ok", text: "")
            case .gemini:
                _ = try await GeminiClient().complete(apiKey: trimmed, model: ModelCatalog.gemini.first ?? "gemini-3.5-flash", promptTemplate: "Reply with: ok", text: "")
            case .openAICompatible:
                guard let baseURL = provider.baseURL, !baseURL.isEmpty,
                      let model = (provider.models ?? []).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    testResult = .failed("Set a base URL and at least one model first")
                    return
                }
                _ = try await OpenAIClient().complete(apiKey: trimmed, baseURL: baseURL, model: model, promptTemplate: "Reply with: ok", text: "")
            case .ollama, .apple:
                return
            }
            testResult = .ok
        } catch OpenAIError.emptyResponse {
            testResult = .ok
        } catch AnthropicError.emptyResponse {
            testResult = .ok
        } catch GeminiError.emptyResponse {
            testResult = .ok
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }

    private func addModel() {
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var models = provider.models ?? []
        guard !models.contains(trimmed) else { newModel = ""; return }
        models.append(trimmed)
        provider.models = models
        newModel = ""
    }

    private func removeModel(at index: Int) {
        guard var models = provider.models, models.indices.contains(index) else { return }
        models.remove(at: index)
        provider.models = models
    }
}
