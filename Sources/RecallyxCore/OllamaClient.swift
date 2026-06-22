import Foundation

/// Where the local Ollama server lives by default. `RECALLYX_OLLAMA_URL`
/// overrides it (used by tests / advanced setups). `AppSettings` re-exports
/// this so the app's settings default matches the core clients' fallback.
public let recallyxDefaultOllamaBaseURL: String =
    ProcessInfo.processInfo.environment["RECALLYX_OLLAMA_URL"] ?? "http://localhost:11434"

public enum OllamaError: LocalizedError {
    case invalidResponse
    case notRunning(String)
    case modelNotFound(String)
    case httpError(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .notRunning(let baseURL):
            return "Ollama isn't reachable at \(baseURL). Install it from ollama.com and run `ollama serve`."
        case .modelNotFound(let name):
            return "Model not found — run `ollama pull \(name)`."
        case .httpError(let code, _): return "HTTP \(code)"
        case .emptyResponse: return "Ollama returned no text"
        }
    }
}

/// Local Ollama client. Mirrors `OpenAIClient`/`AnthropicClient` — raw
/// `URLSession`, `JSONSerialization` request body, `JSONDecoder` response, zero
/// deps — but talks to a local server with **no auth**. Models are addressed as
/// `ollama:<name>` in the model string (so `AIProvider` can route by prefix);
/// the prefix is stripped before the name is sent. Local models can be slow to
/// load on first use, so the timeout is 120s.
public struct OllamaClient {
    public init() {}
    public static let prefix = "ollama:"
    private static let timeout: TimeInterval = 120

    /// Strip the `ollama:` routing prefix to get the bare Ollama model name.
    public static func strippedModel(_ model: String) -> String {
        guard model.lowercased().hasPrefix(prefix) else { return model }
        return String(model.dropFirst(prefix.count))
    }

    /// `imageData` (PNG bytes) opt-in: when non-nil the model is sent Ollama's
    /// multimodal `images` field — raw standard base64 of the bytes, NO `data:`
    /// URL prefix (that's an OpenAI-ism). Only vision-capable local models
    /// (llava, moondream, …) accept it; the facade gates non-vision models out
    /// before we get here. Text-only path (nil) is unchanged.
    public func complete(
        baseURL: String,
        model: String,
        promptTemplate: String,
        text: String,
        imageData: Data? = nil
    ) async throws -> String {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
        guard let url = URL(string: "\(base)/api/generate") else {
            throw OllamaError.notRunning(baseURL)
        }
        let name = Self.strippedModel(model)
        let fullPrompt = applyPromptTemplate(promptTemplate, text: text)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": name,
            "prompt": fullPrompt,
            "stream": false
        ]
        if let imageData {
            // Ollama multimodal: raw standard base64, no `data:` URL prefix.
            body["images"] = [imageData.base64EncodedString()]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Connection refused / host down / timeout — Ollama isn't reachable.
            throw OllamaError.notRunning(base)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            // A 404 from /api/generate means the model isn't pulled.
            if http.statusCode == 404 { throw OllamaError.modelNotFound(name) }
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.httpError(http.statusCode, bodyString)
        }

        let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data)
        guard let result = decoded?.response?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            throw OllamaError.emptyResponse
        }
        return result
    }

    private struct GenerateResponse: Decodable {
        let response: String?
    }
}
