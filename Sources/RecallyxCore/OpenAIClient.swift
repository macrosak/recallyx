import Foundation

public enum OpenAIError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case apiError(String)
    case emptyResponse
    case missingApiKey
    case invalidApiKey

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .httpError(let code, _): return "HTTP \(code)"
        case .apiError(let msg): return msg
        case .emptyResponse: return "API returned no text"
        case .missingApiKey: return "OpenAI API key not set"
        case .invalidApiKey: return "OpenAI API key rejected (401)"
        }
    }
}

/// Chat-completions client. Copied from AI Replace; the same code serves the
/// built-in OpenAI provider and user-added OpenAI-compatible endpoints (Groq /
/// Together / OpenRouter / LM Studio / vLLM / …) via a configurable `baseURL`.
public struct OpenAIClient {
    public init() {}
    /// The OpenAI API base — the default `baseURL`. Custom endpoints pass their own.
    public static let defaultBaseURL = "https://api.openai.com/v1"
    private static let maxTokens = AIClientDefaults.maxOutputTokens

    /// Resolves the chat-completions endpoint from a provider base URL. Accepts a
    /// base like `https://api.groq.com/openai/v1` (→ `…/v1/chat/completions`) or a
    /// full `…/chat/completions` URL (used as-is). Trailing slashes are tolerated.
    public static func chatCompletionsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed) }
        return URL(string: trimmed + "/chat/completions")
    }

    /// `imageData` (PNG bytes) opt-in: when non-nil, the user message `content`
    /// becomes a vision array `[{text}, {image_url: data:image/png;base64,…}]`;
    /// otherwise the existing plain-text shape (unchanged).
    ///
    /// `baseURL` defaults to OpenAI's; custom OpenAI-compatible providers pass
    /// their own endpoint base.
    public func complete(
        apiKey: String,
        baseURL: String = OpenAIClient.defaultBaseURL,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenAIError.missingApiKey }
        guard let endpoint = Self.chatCompletionsURL(baseURL: baseURL) else {
            throw OpenAIError.invalidResponse
        }

        let fullPrompt = applyPromptTemplate(promptTemplate, text: text)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let content: Any
        if let imageData {
            let dataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
            content = [
                ["type": "text", "text": fullPrompt],
                ["type": "image_url", "image_url": ["url": dataURL]],
            ]
        } else {
            content = fullPrompt
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "max_completion_tokens": Self.maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw OpenAIError.invalidApiKey }
            if let msg = decoded?.error?.message { throw OpenAIError.apiError(msg) }
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.httpError(http.statusCode, bodyString)
        }

        if decoded?.choices.first?.finishReason == "length" {
            Log.info("OpenAI response truncated at max_completion_tokens=\(Self.maxTokens)")
        }

        guard let text = decoded?.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw OpenAIError.emptyResponse
        }
        return text
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct APIError: Decodable { let message: String }
        let choices: [Choice]
        let error: APIError?
    }
}

/// AI models exposed in Settings, grouped by provider. The default stays an
/// OpenAI model (backward compatible); Claude models route to `AnthropicClient`
/// and `ollama:*` models to the local `OllamaClient`, by model-id prefix (see
/// `AIProvider`).
public enum ModelCatalog {
    public static let openAI: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-5.4-nano",
        "gpt-5.4-mini",
        "gpt-5.4",
    ]
    public static let anthropic: [String] = [
        "claude-haiku-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-8",
    ]
    /// Google Gemini cloud models — addressed `gemini*` so they route to
    /// `GeminiClient` (BYO-key). Easily updatable as Google ships new GA ids.
    public static let gemini: [String] = [
        "gemini-3.5-flash",
        "gemini-2.5-pro",
        "gemini-3.1-flash-lite",
    ]
    /// Local models served by Ollama — addressed `ollama:<name>` so they route
    /// to `OllamaClient`. Users can also type a custom `ollama:<model>` override.
    /// `llava`/`llama3.2-vision` are multimodal (local OCR / describe-image);
    /// the others are text-only (see `AIProvider.isOllamaVisionModel`).
    public static let ollama: [String] = [
        "ollama:llama3.2",
        "ollama:qwen2.5",
        "ollama:mistral",
        "ollama:llava",
        "ollama:llama3.2-vision",
    ]
    /// On-device Apple Intelligence — addressed `apple:…` so it routes to
    /// `AppleClient`. The suffix is ignored (the OS picks the model); no key,
    /// no URL, macOS 26+ only.
    public static let apple: [String] = ["apple:on-device"]
    /// Existing call sites that iterate every model keep working.
    public static let all: [String] = openAI + anthropic + gemini + ollama + apple
    public static let `default` = "gpt-4o-mini"

    // MARK: - Availability-aware grouping (for the Settings model pickers)

    /// One provider's worth of selectable models, rendered as a `Section` in a
    /// SwiftUI `Picker`.
    public struct ModelGroup: Identifiable {
        public let title: String
        public let models: [String]
        public var id: String { title }
        public init(title: String, models: [String]) {
            self.title = title
            self.models = models
        }
    }

    /// Pure, hermetic flag-driven grouping — kept for its unit tests. Order is
    /// fixed: OpenAI, Anthropic, Google Gemini, Ollama, Apple. **No longer drives
    /// live availability** — `groups(forProviders:)` (the explicit provider list)
    /// does; this stays as a pure reference/test surface.
    public static func groups(openAI: Bool, anthropic: Bool, gemini: Bool, ollama: Bool, apple: Bool) -> [ModelGroup] {
        var result: [ModelGroup] = []
        if openAI { result.append(ModelGroup(title: "OpenAI", models: self.openAI)) }
        if anthropic { result.append(ModelGroup(title: "Anthropic", models: self.anthropic)) }
        if gemini { result.append(ModelGroup(title: "Google Gemini", models: self.gemini)) }
        if ollama { result.append(ModelGroup(title: "Ollama (local)", models: self.ollama)) }
        if apple { result.append(ModelGroup(title: "Apple Intelligence (on-device)", models: self.apple)) }
        return result
    }

    /// The selectable model groups derived from the user's explicit provider
    /// list — the source of truth that replaced the keychain-presence/always-on
    /// availability heuristic. **Pure and order-preserving:** each *enabled*
    /// entry, in list order (drag-reorder = picker group order), contributes one
    /// `ModelGroup`:
    /// - built-in cloud/Ollama/Apple → the catalog's fixed model list under the
    ///   provider's `displayName`,
    /// - a custom (`openAICompatible`) provider → its user-entered `models`
    ///   tagged as `custom:<id>:<model>` (empty/blank model lists are skipped).
    ///
    /// Drives both Settings pickers + the Actions step picker so they share one
    /// source. Test THIS; `availableGroups(for:)` just forwards the live list.
    public static func groups(forProviders providers: [ProviderConfig]) -> [ModelGroup] {
        var result: [ModelGroup] = []
        for provider in providers where provider.enabled {
            switch provider.type {
            case .openai:
                result.append(ModelGroup(title: provider.displayName, models: openAI))
            case .anthropic:
                result.append(ModelGroup(title: provider.displayName, models: anthropic))
            case .gemini:
                result.append(ModelGroup(title: provider.displayName, models: gemini))
            case .ollama:
                result.append(ModelGroup(title: provider.displayName, models: ollama))
            case .apple:
                result.append(ModelGroup(title: provider.displayName, models: apple))
            case .openAICompatible:
                let models = (provider.models ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { provider.customModelID($0) }
                if !models.isEmpty {
                    result.append(ModelGroup(title: provider.displayName, models: models))
                }
            }
        }
        return result
    }

    /// Live convenience used by the views: forwards the user's explicit provider
    /// list to the pure `groups(forProviders:)` builder.
    public static func availableGroups(for providers: [ProviderConfig]) -> [ModelGroup] {
        groups(forProviders: providers)
    }

    /// Keeps the `Picker`'s current selection selectable: a SwiftUI `Picker`
    /// whose bound value isn't among its tags renders blank, so if a non-empty
    /// `selected` (e.g. a `claude-…` override after the Anthropic key was
    /// removed) isn't in any group, append a trailing single-item "Configured"
    /// group for it. Pure and hermetic — unit-tested.
    public static func groupsPreservingSelection(_ groups: [ModelGroup], selected: String) -> [ModelGroup] {
        guard !selected.isEmpty else { return groups }
        if groups.contains(where: { $0.models.contains(selected) }) { return groups }
        return groups + [ModelGroup(title: "Configured", models: [selected])]
    }
}
