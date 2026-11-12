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
/// deps. `max_tokens` is required; no `temperature`/`top_p` (rejected on current
/// Claude models). `thinking` is sent only when a step sets a reasoning effort
/// (see `requestBody`); only `text` blocks are ever returned.
public struct AnthropicClient {
    public init() {}
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxTokens = AIClientDefaults.maxOutputTokens
    private static let version = "2023-06-01"

    /// `imageData` (PNG bytes) opt-in: when non-nil, the user message `content`
    /// becomes a vision array `[{image, source: base64 image/png}, {text}]`;
    /// otherwise the existing plain-text shape (unchanged).
    public func complete(
        apiKey: String,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil,
        effort: Effort? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicError.missingApiKey }

        let fullPrompt = applyPromptTemplate(promptTemplate, text: text)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AIClientDefaults.timeout(for: effort)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")

        let body = Self.requestBody(model: model, fullPrompt: fullPrompt, imageData: imageData, effort: effort)
        let maxTokens = body["max_tokens"] as? Int ?? Self.maxTokens
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

        if decoded?.stopReason == "max_tokens" {
            Log.info("Anthropic response truncated at max_tokens=\(maxTokens)")
        }

        // Only `text` blocks — `thinking` / `redacted_thinking` blocks (present
        // when a step sets an effort) must never reach the paste. A refusal
        // (HTTP 200, no text block) lands in the empty-response error too.
        guard let decoded, let text = Self.resultText(from: decoded) else {
            throw AnthropicError.emptyResponse
        }
        return text
    }

    /// Thinking budget per effort level for models that still use the legacy
    /// `thinking: {type: "enabled", budget_tokens}` shape (min 1024).
    public static func thinkingBudget(for effort: Effort) -> Int {
        switch effort {
        case .low: return 1024
        case .medium: return 4096
        case .high: return 16000
        }
    }

    /// True for older Claude models that don't accept `output_config.effort`
    /// and need a fixed `budget_tokens` to think (Haiku 4.5, Sonnet 4.5, Opus
    /// 4.5/4.1/4, Sonnet 4, Claude 3.x). Newer / unknown ids use the documented
    /// effort parameter — `budget_tokens` is rejected with a 400 on current
    /// Claude 5-generation models.
    public static func usesLegacyThinkingBudget(model: String) -> Bool {
        let m = model.lowercased()
        let legacyPrefixes = [
            "claude-3",
            "claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5",
            "claude-opus-4-1", "claude-opus-4-0", "claude-sonnet-4-0",
            "claude-opus-4-2025", "claude-sonnet-4-2025",
        ]
        return legacyPrefixes.contains { m.hasPrefix($0) }
    }

    /// Pure Messages-API request body. With `effort == nil` (Default) this is
    /// byte-for-byte the pre-feature body (no `thinking`, `max_tokens` 4096).
    /// With an effort:
    ///   • current models → `thinking: {type: adaptive}` +
    ///     `output_config: {effort}` and `max_tokens` raised to the reasoning cap
    ///     (thinking counts against it);
    ///   • legacy models (`usesLegacyThinkingBudget`) → `thinking: {type:
    ///     enabled, budget_tokens}` with `max_tokens = budget + 4096` (must
    ///     exceed the budget).
    public static func requestBody(
        model: String,
        fullPrompt: String,
        imageData: Data? = nil,
        effort: Effort? = nil
    ) -> [String: Any] {
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

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]]
        ]
        if let effort {
            if usesLegacyThinkingBudget(model: model) {
                let budget = thinkingBudget(for: effort)
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
                body["max_tokens"] = budget + AIClientDefaults.maxOutputTokens
            } else {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": effort.rawValue]
                body["max_tokens"] = AIClientDefaults.maxOutputTokensWithReasoning
            }
        }
        return body
    }

    /// Parses a raw Messages-API response and returns the trimmed result text
    /// (text blocks only, joined), or nil when there is none. Pure + testable.
    public static func resultText(fromResponseData data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data) else { return nil }
        return resultText(from: decoded)
    }

    private static func resultText(from decoded: MessagesResponse) -> String? {
        let text = (decoded.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct APIError: Decodable { let message: String }
        let content: [Block]?
        let error: APIError?
        let stopReason: String?
        enum CodingKeys: String, CodingKey {
            case content
            case error
            case stopReason = "stop_reason"
        }
    }
}
