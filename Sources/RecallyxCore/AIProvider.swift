import Foundation

/// Shared AI-step plumbing used by every client (cloud + local).
public enum AIClientDefaults {
    /// Output-token cap requested from the cloud chat APIs. A high default so
    /// OCR ("Extract text") and "Summarize" on long clips don't get silently cut
    /// off mid-sentence at the old 1000-token ceiling. The local Ollama/Apple
    /// paths don't take a cap.
    public static let maxOutputTokens = 4096
}

/// Fill an AI-step prompt template with the clip text. When the template
/// contains the `{{TEXT}}` placeholder, substitute it; when it doesn't (a saved
/// prompt that forgot the placeholder), **append** the input on its own line
/// instead of silently dropping it — so the model still sees the clip. The
/// ad-hoc Custom… path ensures `{{TEXT}}` upstream, so it never double-appends.
/// Centralizes what was a per-client `replacingOccurrences(of: "{{TEXT}}", …)`.
public func applyPromptTemplate(_ template: String, text: String) -> String {
    if template.contains("{{TEXT}}") {
        return template.replacingOccurrences(of: "{{TEXT}}", with: text)
    }
    return template + "\n\n" + text
}

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
    /// A user-added OpenAI-compatible endpoint (Groq / Together / OpenRouter /
    /// LM Studio / vLLM / …). Models are addressed `custom:<providerID>:<model>`;
    /// the facade resolves the id to a (baseURL, keychain account) and dispatches
    /// to `OpenAIClient` pointed at that base URL.
    case openAICompatible

    public static func provider(for model: String) -> AIProvider {
        let lower = model.lowercased()
        if lower.hasPrefix("custom:") { return .openAICompatible }
        if lower.hasPrefix("apple:") { return .apple }
        if lower.hasPrefix("ollama:") { return .ollama }
        if lower.hasPrefix("gemini") { return .gemini }
        return lower.hasPrefix("claude") ? .anthropic : .openai
    }

    /// Splits a `custom:<providerID>:<model>` id into its provider id and the
    /// real model name to send upstream. Returns `nil` for a non-custom or
    /// malformed id (missing either component). The model name may itself contain
    /// colons (e.g. `org/model:tag`), so only the first two `:` are separators.
    public static func parseCustomModel(_ model: String) -> (providerID: String, model: String)? {
        let parts = model.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].lowercased() == "custom",
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    /// Cloud providers store an API key in the Keychain; the local providers
    /// (Ollama, on-device Apple Intelligence) have none, so this is `nil` for
    /// `.ollama`/`.apple` (the facade skips the key check for local).
    public var keychain: KeychainStore? {
        switch self {
        case .openai: return .openAIKey
        case .anthropic: return .anthropicKey
        case .gemini: return .geminiKey
        // Local providers have no key; custom endpoints use a per-provider
        // account the facade resolves from the model id (not a fixed store).
        case .ollama, .apple, .openAICompatible: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama"
        case .apple: return "Apple Intelligence"
        case .openAICompatible: return "Custom (OpenAI-compatible)"
        }
    }

    /// Whether this provider can take image input as a whole. Cloud providers
    /// (OpenAI, Anthropic) do; the local providers do not at the provider level
    /// — Ollama vision is **per-model** (see `supportsVision(forModel:)`), so
    /// this flag stays `false` for `.ollama`. Prefer the model-aware static
    /// check at call sites that have a concrete model id.
    public var supportsVision: Bool {
        switch self {
        // Custom OpenAI-compatible endpoints vary; we don't pre-block — let the
        // server reject an image if it can't handle one (see supportsVision(forModel:)).
        case .openai, .anthropic, .gemini, .openAICompatible: return true
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
        // Custom endpoints are treated as vision-capable — OpenAI-compatible
        // servers differ, so we let the server reject rather than pre-block here.
        case .openai, .anthropic, .gemini, .openAICompatible: return true
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
    /// Resolved config for a custom endpoint id: its base URL and the keychain
    /// account that stores its API key.
    public typealias CustomEndpoint = (baseURL: String, keychainAccount: String)

    private let openAI = OpenAIClient()
    private let anthropic = AnthropicClient()
    private let gemini = GeminiClient()
    private let ollama = OllamaClient()
    private let apple = AppleClient()
    private let ollamaBaseURL: () -> String
    private let customEndpoint: (_ providerID: String) -> CustomEndpoint?

    public init(
        ollamaBaseURL: @escaping () -> String = { recallyxDefaultOllamaBaseURL },
        customEndpoint: @escaping (_ providerID: String) -> CustomEndpoint? = { _ in nil }
    ) {
        self.ollamaBaseURL = ollamaBaseURL
        self.customEndpoint = customEndpoint
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
        case .openAICompatible:
            // `custom:<providerID>:<model>` → resolve the endpoint, strip the
            // prefix to recover the real model, read its key, and dispatch to the
            // OpenAI-compatible client at the configured base URL.
            guard let parsed = AIProvider.parseCustomModel(model),
                  let endpoint = customEndpoint(parsed.providerID) else {
                throw ActionError.customEndpointUnavailable
            }
            let key = KeychainStore.custom(account: endpoint.keychainAccount).read() ?? ""
            return try await openAI.complete(
                apiKey: key,
                baseURL: endpoint.baseURL,
                model: parsed.model,
                promptTemplate: prompt,
                text: input,
                imageData: imageData
            )
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
