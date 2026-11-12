import Foundation

public enum GeminiError: LocalizedError {
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
        case .missingApiKey: return "Google Gemini API key not set"
        case .invalidApiKey: return "Google Gemini API key rejected"
        }
    }
}

/// `generateContent` client for Google Gemini. Mirrors `AnthropicClient` — raw
/// `URLSession`, `JSONSerialization` request body, `JSONDecoder` response, zero
/// deps. The key rides as a `?key=` query param; the model id is part of the
/// path. A reasoning effort (if set) rides in `generationConfig.thinkingConfig`.
public struct GeminiClient {
    public init() {}
    private static let base = "https://generativelanguage.googleapis.com/v1beta/models"

    /// `imageData` (PNG bytes) opt-in: when non-nil, an `inline_data` part is
    /// appended to the content `parts` (mime_type image/png, raw base64, no
    /// `data:` prefix); otherwise the existing plain-text shape (unchanged).
    public func complete(
        apiKey: String,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil,
        effort: Effort? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.missingApiKey }

        let fullPrompt = applyPromptTemplate(promptTemplate, text: text)

        guard let key = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.base)/\(model):generateContent?key=\(key)") else {
            throw GeminiError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AIClientDefaults.timeout(for: effort)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = Self.requestBody(fullPrompt: fullPrompt, imageData: imageData, effort: effort)
        let maxTokens = (body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int
            ?? AIClientDefaults.maxOutputTokens
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(GenerateContentResponse.self, from: data)

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw GeminiError.invalidApiKey }
            if let msg = decoded?.error?.message {
                // A 400 "API key not valid" is the common bad-key shape.
                if msg.localizedCaseInsensitiveContains("api key not valid") {
                    throw GeminiError.invalidApiKey
                }
                throw GeminiError.apiError(msg)
            }
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.httpError(http.statusCode, bodyString)
        }

        if decoded?.candidates?.first?.finishReason == "MAX_TOKENS" {
            Log.info("Gemini response truncated at maxOutputTokens=\(maxTokens)")
        }

        // First non-thought text part of the first candidate; a safety block
        // (HTTP 200, no candidate text) lands here too.
        guard let decoded, let text = Self.resultText(from: decoded) else {
            throw GeminiError.emptyResponse
        }
        return text
    }

    /// Pure `generateContent` request body. With `effort == nil` (Default) this
    /// is byte-for-byte the pre-feature body. With an effort it adds
    /// `generationConfig.thinkingConfig.thinkingLevel` (`low`/`medium`/`high` —
    /// the level knob current Gemini models document) and raises
    /// `maxOutputTokens` to the reasoning cap (thinking tokens count against it).
    /// Thoughts aren't requested (`includeThoughts` unset).
    public static func requestBody(
        fullPrompt: String,
        imageData: Data? = nil,
        effort: Effort? = nil
    ) -> [String: Any] {
        var parts: [[String: Any]] = [["text": fullPrompt]]
        if let imageData {
            parts.append([
                "inline_data": [
                    "mime_type": "image/png",
                    "data": imageData.base64EncodedString(),
                ]
            ])
        }

        // Without `maxOutputTokens`, Gemini caps output low and silently
        // truncates long OCR/summaries; match the other clients' high default.
        var generationConfig: [String: Any] = ["maxOutputTokens": AIClientDefaults.maxOutputTokens]
        if let effort {
            generationConfig["maxOutputTokens"] = AIClientDefaults.maxOutputTokensWithReasoning
            generationConfig["thinkingConfig"] = ["thinkingLevel": effort.rawValue]
        }
        return [
            "contents": [["parts": parts]],
            "generationConfig": generationConfig
        ]
    }

    /// Parses a raw `generateContent` response and returns the first trimmed
    /// non-thought text part, or nil. Pure + testable.
    public static func resultText(fromResponseData data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(GenerateContentResponse.self, from: data) else { return nil }
        return resultText(from: decoded)
    }

    private static func resultText(from decoded: GenerateContentResponse) -> String? {
        // Skip `thought: true` parts so reasoning summaries never get pasted.
        guard let text = decoded.candidates?.first?.content?.parts?
            .filter({ $0.thought != true })
            .compactMap({ $0.text })
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private struct GenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String?; let thought: Bool? }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        struct APIError: Decodable { let message: String }
        let candidates: [Candidate]?
        let error: APIError?
    }
}
