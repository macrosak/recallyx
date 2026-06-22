import Foundation

enum OpenAIError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case apiError(String)
    case emptyResponse
    case missingApiKey
    case invalidApiKey

    var errorDescription: String? {
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
struct OpenAIClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let maxTokens = 1000

    /// `imageData` (PNG bytes) opt-in: when non-nil, the user message `content`
    /// becomes a vision array `[{text}, {image_url: data:image/png;base64,…}]`;
    /// otherwise the existing plain-text shape (unchanged).
    func complete(
        apiKey: String,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenAIError.missingApiKey }

        let fullPrompt = promptTemplate.replacingOccurrences(of: "{{TEXT}}", with: text)

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
enum ModelCatalog {
    static let openAI: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-5.4-nano",
        "gpt-5.4-mini",
        "gpt-5.4",
    ]
    static let anthropic: [String] = [
        "claude-haiku-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-8",
    ]
    /// Local models served by Ollama — addressed `ollama:<name>` so they route
    /// to `OllamaClient`. Users can also type a custom `ollama:<model>` override.
    static let ollama: [String] = [
        "ollama:llama3.2",
        "ollama:qwen2.5",
        "ollama:mistral",
    ]
    /// On-device Apple Intelligence — addressed `apple:…` so it routes to
    /// `AppleClient`. The suffix is ignored (the OS picks the model); no key,
    /// no URL, macOS 26+ only.
    static let apple: [String] = ["apple:on-device"]
    /// Existing call sites that iterate every model keep working.
    static let all: [String] = openAI + anthropic + ollama + apple
    static let `default` = "gpt-4o-mini"
}
