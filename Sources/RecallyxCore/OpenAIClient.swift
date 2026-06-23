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

/// Chat-completions client. Copied from AI Replace.
public struct OpenAIClient {
    public init() {}
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let maxTokens = AIClientDefaults.maxOutputTokens

    /// `imageData` (PNG bytes) opt-in: when non-nil, the user message `content`
    /// becomes a vision array `[{text}, {image_url: data:image/png;base64,…}]`;
    /// otherwise the existing plain-text shape (unchanged).
    public func complete(
        apiKey: String,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenAIError.missingApiKey }

        let fullPrompt = applyPromptTemplate(promptTemplate, text: text)

        var request = URLRequest(url: Self.endpoint)
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

    /// Pure, hermetic grouping — produces the provider sections to show, gated
    /// purely by the passed flags. Order is fixed: OpenAI, Anthropic, Google
    /// Gemini, Ollama, Apple. Test THIS; `availableGroups()` computes the flags
    /// from live config.
    public static func groups(openAI: Bool, anthropic: Bool, gemini: Bool, ollama: Bool, apple: Bool) -> [ModelGroup] {
        var result: [ModelGroup] = []
        if openAI { result.append(ModelGroup(title: "OpenAI", models: self.openAI)) }
        if anthropic { result.append(ModelGroup(title: "Anthropic", models: self.anthropic)) }
        if gemini { result.append(ModelGroup(title: "Google Gemini", models: self.gemini)) }
        if ollama { result.append(ModelGroup(title: "Ollama (local)", models: self.ollama)) }
        if apple { result.append(ModelGroup(title: "Apple Intelligence (on-device)", models: self.apple)) }
        return result
    }

    /// Live-config convenience used by the views: cloud providers appear only
    /// when their Keychain key is set, Apple only when the OS can run it, Ollama
    /// always (local, keyless — deliberate v1 choice). Reads the keychain + OS
    /// each call so newly-saved keys show up on the next view appearance.
    public static func availableGroups() -> [ModelGroup] {
        func keySet(_ store: KeychainStore) -> Bool {
            guard let key = store.read() else { return false }
            return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return groups(
            openAI: keySet(.openAIKey),
            anthropic: keySet(.anthropicKey),
            gemini: keySet(.geminiKey),
            ollama: true,
            apple: AppleClient.isAvailable
        )
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
