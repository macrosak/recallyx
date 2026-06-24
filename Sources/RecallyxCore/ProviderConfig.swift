import Foundation

/// The kind of AI backend a `ProviderConfig` represents. The five built-ins
/// mirror `AIProvider`; `.openAICompatible` is a user-added custom endpoint
/// (Groq / Together / OpenRouter / LM Studio / vLLM / …) that speaks the OpenAI
/// chat-completions protocol behind a user-supplied base URL + key.
public enum ProviderType: String, Codable, CaseIterable, Equatable, Sendable {
    case openai
    case anthropic
    case gemini
    case ollama
    case apple
    case openAICompatible

    /// Default human-facing name for a freshly added provider of this type.
    public var defaultDisplayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (local)"
        case .apple: return "Apple Intelligence (on-device)"
        case .openAICompatible: return "Custom (OpenAI-compatible)"
        }
    }

    /// The fixed keychain account a built-in cloud provider stores its key under,
    /// or `nil` for the local (`.ollama`/`.apple`) and custom types (custom uses a
    /// per-provider account derived from its id).
    public var builtinKeychainAccount: String? {
        switch self {
        case .openai: return KeychainStore.openAIKey.account
        case .anthropic: return KeychainStore.anthropicKey.account
        case .gemini: return KeychainStore.geminiKey.account
        case .ollama, .apple, .openAICompatible: return nil
        }
    }
}

/// One entry in the user's explicit provider list. Surfaced in the new Providers
/// Settings tab; an enabled entry makes that provider's models appear in the
/// pickers. **Holds only references, never secrets** — the API key lives in the
/// Keychain, addressed by `keychainAccount`.
///
/// All per-type config is optional so `Codable` stays simple and so an old
/// settings blob (no `providers`) round-trips when the migration seeds the list.
public struct ProviderConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var type: ProviderType
    public var enabled: Bool
    public var displayName: String
    /// `.ollama` server URL + `.openAICompatible` endpoint base URL.
    public var baseURL: String?
    /// Keychain account that stores this provider's API key (cloud + custom).
    public var keychainAccount: String?
    /// `.openAICompatible` only: the user-entered model ids served by this
    /// endpoint (bare names like `llama-3.1-70b`, addressed `custom:<id>:<name>`).
    public var models: [String]?

    public init(
        id: UUID = UUID(),
        type: ProviderType,
        enabled: Bool = true,
        displayName: String? = nil,
        baseURL: String? = nil,
        keychainAccount: String? = nil,
        models: [String]? = nil
    ) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.displayName = displayName ?? type.defaultDisplayName
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
        self.models = models
    }

    /// The keychain account a custom provider's key is stored under — derived
    /// from its id so two custom endpoints never collide. Stable across renames.
    public static func customKeychainAccount(for id: UUID) -> String {
        "custom-\(id.uuidString.lowercased())-api-key"
    }

    /// The picker model-id namespace for a custom provider's model, e.g.
    /// `custom:<uuid>:gpt-4o`. Routing strips this back in the facade.
    public func customModelID(_ model: String) -> String {
        "custom:\(id.uuidString.lowercased()):\(model)"
    }
}

// MARK: - Migration seeding

extension ProviderConfig {
    /// Builds the initial provider list from the *current* installed reality —
    /// used by the back-compat decoder when an old settings blob has no
    /// `providers` key, so a working setup never vanishes:
    /// - a cloud provider (OpenAI / Anthropic / Gemini) is added iff its keychain
    ///   key currently exists,
    /// - Apple is added iff `AppleClient.isAvailable`,
    /// - Ollama is always added (it was always-on before — existing users keep
    ///   their Ollama models; new users add it deliberately, the intended change),
    /// - no custom endpoints are seeded.
    ///
    /// The keychain/OS lookups are injectable so the migration test stays
    /// hermetic. Order matches the picker group order.
    public static func seedFromCurrentReality(
        hasOpenAIKey: Bool = ProviderConfig.keychainHasKey(.openAIKey),
        hasAnthropicKey: Bool = ProviderConfig.keychainHasKey(.anthropicKey),
        hasGeminiKey: Bool = ProviderConfig.keychainHasKey(.geminiKey),
        appleAvailable: Bool = AppleClient.isAvailable,
        ollamaBaseURL: String = recallyxDefaultOllamaBaseURL
    ) -> [ProviderConfig] {
        var result: [ProviderConfig] = []
        if hasOpenAIKey {
            result.append(ProviderConfig(type: .openai, keychainAccount: KeychainStore.openAIKey.account))
        }
        if hasAnthropicKey {
            result.append(ProviderConfig(type: .anthropic, keychainAccount: KeychainStore.anthropicKey.account))
        }
        if hasGeminiKey {
            result.append(ProviderConfig(type: .gemini, keychainAccount: KeychainStore.geminiKey.account))
        }
        result.append(ProviderConfig(type: .ollama, baseURL: ollamaBaseURL))
        if appleAvailable {
            result.append(ProviderConfig(type: .apple))
        }
        return result
    }

    /// Whether a keychain item currently holds a non-empty key.
    public static func keychainHasKey(_ store: KeychainStore) -> Bool {
        guard let key = store.read() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
