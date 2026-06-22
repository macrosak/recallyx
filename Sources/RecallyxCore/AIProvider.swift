import Foundation

/// Which backend serves a given AI step. The model-id string is authoritative:
/// `apple:*` routes to the on-device Apple Intelligence model, `ollama:*` to the
/// local Ollama server, `claude*` (case-insensitive) to Anthropic, everything
/// else to OpenAI (the default — backward compatible, no schema migration). A
/// further provider slots in here: add a case + (for cloud providers) its
/// keychain account + a client dispatch in `AIClient`.
public enum AIProvider {
    case openai
    case anthropic
    case gemini
    case ollama
    case apple

    public static func provider(for model: String) -> AIProvider {
        let lower = model.lowercased()
        if lower.hasPrefix("apple:") { return .apple }
        if lower.hasPrefix("ollama:") { return .ollama }
        if lower.hasPrefix("gemini") { return .gemini }
        return lower.hasPrefix("claude") ? .anthropic : .openai
    }

    /// Cloud providers store an API key in the Keychain; the local providers
    /// (Ollama, on-device Apple Intelligence) have none, so this is `nil` for
    /// `.ollama`/`.apple` (the facade skips the key check for local).
    public var keychain: KeychainStore? {
        switch self {
        case .openai: return .openAIKey
        case .anthropic: return .anthropicKey
        case .gemini: return .geminiKey
        case .ollama, .apple: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama"
        case .apple: return "Apple Intelligence"
        }
    }

    /// Whether this provider can take image input as a whole. Cloud providers
    /// (OpenAI, Anthropic) do; the local providers do not at the provider level
    /// — Ollama vision is **per-model** (see `supportsVision(forModel:)`), so
    /// this flag stays `false` for `.ollama`. Prefer the model-aware static
    /// check at call sites that have a concrete model id.
    public var supportsVision: Bool {
        switch self {
        case .openai, .anthropic, .gemini: return true
        case .ollama, .apple: return false
        }
    }

    /// Model-aware vision gate. Ollama vision is **per-model** — only specific
    /// local models are multimodal (llava, llava-llama3, llama3.2-vision,
    /// bakllava, moondream, minicpm-v); text-only locals (llama3.2, qwen2.5,
    /// mistral) cannot take an image. Cloud providers are always vision-capable;
    /// on-device Apple Intelligence is text-only in v1.
    public static func supportsVision(forModel model: String) -> Bool {
        switch provider(for: model) {
        case .openai, .anthropic, .gemini: return true
        case .apple: return false
        case .ollama: return isOllamaVisionModel(model)
        }
    }

    /// Substring allowlist on the prefix-stripped, lowercased model name.
    /// `"llava"` covers llava/llava-llama3; `"vision"` covers llama3.2-vision; a
    /// substring match so a custom tag like `ollama:llava:13b` still counts.
    public static func isOllamaVisionModel(_ model: String) -> Bool {
        let name = OllamaClient.strippedModel(model).lowercased()
        let visionMarkers = ["llava", "vision", "bakllava", "moondream", "minicpm-v"]
        return visionMarkers.contains { name.contains($0) }
    }
}

/// Provider-routing facade: picks the provider by model id, reads that
/// provider's key from the keychain (cloud only), and dispatches to the right
/// client. `ActionRunner` calls this instead of branching on provider itself. A
/// missing key throws `ActionError.missingApiKey` naming the right provider.
/// `.ollama` is local (no key) — the facade dispatches straight to the client,
/// reading the configured base URL.
public struct AIClient {
    private let openAI = OpenAIClient()
    private let anthropic = AnthropicClient()
    private let gemini = GeminiClient()
    private let ollama = OllamaClient()
    private let apple = AppleClient()
    private let ollamaBaseURL: () -> String

    public init(ollamaBaseURL: @escaping () -> String = { recallyxDefaultOllamaBaseURL }) {
        self.ollamaBaseURL = ollamaBaseURL
    }

    /// `imageData` (PNG bytes) opt-in: when non-nil the prompt runs as a vision
    /// request. The gate is **model-aware** (`supportsVision(forModel:)`) since
    /// Ollama vision is per-model — a non-vision model with an image throws
    /// `ActionError.imageNotSupported`; a vision-capable model passes it through.
    public func complete(prompt: String, model: String, input: String, imageData: Data? = nil) async throws -> String {
        let provider = AIProvider.provider(for: model)
        if imageData != nil, !AIProvider.supportsVision(forModel: model) {
            throw ActionError.imageNotSupported
        }
        switch provider {
        case .apple:
            return try await apple.complete(model: model, promptTemplate: prompt, text: input)
        case .ollama:
            return try await ollama.complete(baseURL: ollamaBaseURL(), model: model, promptTemplate: prompt, text: input, imageData: imageData)
        case .openai, .anthropic, .gemini:
            guard let apiKey = provider.keychain?.read(), !apiKey.isEmpty else {
                throw ActionError.missingApiKey(provider)
            }
            switch provider {
            case .openai:
                return try await openAI.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input, imageData: imageData)
            case .anthropic:
                return try await anthropic.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input, imageData: imageData)
            default:
                return try await gemini.complete(apiKey: apiKey, model: model, promptTemplate: prompt, text: input, imageData: imageData)
            }
        }
    }
}
