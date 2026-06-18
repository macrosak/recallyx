import Foundation

/// Which backend serves a given AI step. The model-id string is authoritative:
/// `ollama:*` routes to the local Ollama server, `claude*` (case-insensitive) to
/// Anthropic, everything else to OpenAI (the default — backward compatible, no
/// schema migration). A further provider slots in here: add a case + (for cloud
/// providers) its keychain account + a client dispatch in `AIClient`.
enum AIProvider {
    case openai
    case anthropic
    case ollama

    static func provider(for model: String) -> AIProvider {
        let lower = model.lowercased()
        if lower.hasPrefix("ollama:") { return .ollama }
        return lower.hasPrefix("claude") ? .anthropic : .openai
    }

    /// Cloud providers store an API key in the Keychain; the local Ollama
    /// provider has none, so this is `nil` for `.ollama` (the facade skips the
    /// key check for local).
    var keychain: KeychainStore? {
        switch self {
        case .openai: return .openAIKey
        case .anthropic: return .anthropicKey
        case .ollama: return nil
        }
    }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        }
    }
}

/// Provider-routing facade: picks the provider by model id, reads that
/// provider's key from the keychain (cloud only), and dispatches to the right
/// client. `ActionRunner` calls this instead of branching on provider itself. A
/// missing key throws `ActionError.missingApiKey` naming the right provider.
/// `.ollama` is local (no key) — the facade dispatches straight to the client,
/// reading the configured base URL.
struct AIClient {
    private let openAI = OpenAIClient()
    private let anthropic = AnthropicClient()
    private let ollama = OllamaClient()
    private let ollamaBaseURL: () -> String

    init(ollamaBaseURL: @escaping () -> String = { AppSettings.defaultOllamaBaseURL }) {
        self.ollamaBaseURL = ollamaBaseURL
    }

    func complete(prompt: String, model: String, input: String) async throws -> String {
        let provider = AIProvider.provider(for: model)
        switch provider {
        case .ollama:
            return try await ollama.complete(baseURL: ollamaBaseURL(), model: model, promptTemplate: prompt, text: input)
        case .openai, .anthropic:
            guard let apiKey = provider.keychain?.read(), !apiKey.isEmpty else {
                throw ActionError.missingApiKey(provider)
            }
            if provider == .openai {
                return try await openAI.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input)
            } else {
                return try await anthropic.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input)
            }
        }
    }
}
