import Foundation

/// Which backend serves a given AI step. The model-id string is authoritative:
/// `claude*` (case-insensitive) routes to Anthropic, everything else to OpenAI
/// (the default — backward compatible, no schema migration). A third provider
/// slots in here: add a case + its keychain account + a client dispatch in
/// `AIClient`.
enum AIProvider {
    case openai
    case anthropic

    static func provider(for model: String) -> AIProvider {
        model.lowercased().hasPrefix("claude") ? .anthropic : .openai
    }

    var keychain: KeychainStore {
        switch self {
        case .openai: return .openAIKey
        case .anthropic: return .anthropicKey
        }
    }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }
}

/// Provider-routing facade: picks the provider by model id, reads that
/// provider's key from the keychain, and dispatches to the right client.
/// `ActionRunner` calls this instead of branching on provider itself. A missing
/// key throws `ActionError.missingApiKey` naming the right provider.
struct AIClient {
    private let openAI = OpenAIClient()
    private let anthropic = AnthropicClient()

    func complete(prompt: String, model: String, input: String) async throws -> String {
        let provider = AIProvider.provider(for: model)
        guard let apiKey = provider.keychain.read(), !apiKey.isEmpty else {
            throw ActionError.missingApiKey(provider)
        }
        switch provider {
        case .openai:
            return try await openAI.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input)
        case .anthropic:
            return try await anthropic.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input)
        }
    }
}
