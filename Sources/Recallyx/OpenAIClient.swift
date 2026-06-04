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

    func complete(
        apiKey: String,
        model: String,
        promptTemplate: String,
        text: String
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenAIError.missingApiKey }

        let fullPrompt = promptTemplate.replacingOccurrences(of: "{{TEXT}}", with: text)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": fullPrompt]],
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

/// OpenAI chat models exposed in Settings.
enum ModelCatalog {
    static let all: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-5.4-nano",
        "gpt-5.4-mini",
        "gpt-5.4",
    ]
    static let `default` = "gpt-4o-mini"
}
