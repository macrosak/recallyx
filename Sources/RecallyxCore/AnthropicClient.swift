import Foundation

public enum AnthropicError: LocalizedError {
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
        case .missingApiKey: return "Anthropic API key not set"
        case .invalidApiKey: return "Anthropic API key rejected (401)"
        }
    }
}

/// Messages-API client for Anthropic/Claude. Mirrors `OpenAIClient` — raw
/// `URLSession`, `JSONSerialization` request body, `JSONDecoder` response, zero
/// deps. `max_tokens` is required; no `thinking`/`temperature`/`top_p` (these are
/// simple, fast text transforms — omitting thinking keeps the output clean, and
/// the sampling params are rejected on current Claude models).
public struct AnthropicClient {
    public init() {}
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxTokens = 1000
    private static let version = "2023-06-01"

    /// `imageData` (PNG bytes) opt-in: when non-nil, the user message `content`
    /// becomes a vision array `[{image, source: base64 image/png}, {text}]`;
    /// otherwise the existing plain-text shape (unchanged).
    public func complete(
        apiKey: String,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicError.missingApiKey }

        let fullPrompt = promptTemplate.replacingOccurrences(of: "{{TEXT}}", with: text)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")

        let content: Any
        if let imageData {
            content = [
                ["type": "image", "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": imageData.base64EncodedString(),
                ]],
                ["type": "text", "text": fullPrompt],
            ]
        } else {
            content = fullPrompt
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "messages": [["role": "user", "content": content]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data)

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AnthropicError.invalidApiKey }
            if let msg = decoded?.error?.message { throw AnthropicError.apiError(msg) }
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.httpError(http.statusCode, bodyString)
        }

        // First text block; a refusal (HTTP 200, no text block) lands here too.
        guard let text = decoded?.content?
            .first(where: { $0.type == "text" })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AnthropicError.emptyResponse
        }
        return text
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct APIError: Decodable { let message: String }
        let content: [Block]?
        let error: APIError?
    }
}
