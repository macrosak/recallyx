import Foundation

/// Pure response parsers for each provider's "list models" endpoint. Each turns
/// the raw JSON body into a de-duplicated list of **bare, provider-native** model
/// ids (no `ollama:`/`custom:` picker namespace — that's applied later, by
/// `ModelCatalog.groups(forProviders:liveModels:)`). All are total: malformed /
/// unexpected JSON yields `[]` (never throws), so a fetch failure falls back to
/// the hardcoded `ModelCatalog`. Filtering choices are documented per provider.
/// Unit-tested with fixture strings — no network.

/// OpenAI `GET {base}/v1/models` (also serves custom OpenAI-compatible endpoints).
public enum OpenAIModelList {
    /// A chat model id starts with one of these (case-insensitive) …
    static let includePrefixes = ["gpt", "chatgpt"]
    /// … unless it also contains one of these — the non-chat model families the
    /// `/models` list mixes in (embeddings, TTS/audio, transcription, image gen,
    /// moderation, realtime, web-search-preview, and the legacy `-instruct`
    /// completion model).
    static let excludeSubstrings = [
        "embedding", "tts", "whisper", "dall-e", "dalle", "moderation",
        "realtime", "audio", "transcribe", "search", "instruct", "image",
        "davinci", "babbage", "codex",
    ]
    /// Keep the list picker-sized; the raw list can run to dozens.
    public static let cap = 25

    /// Whether an OpenAI model id names a chat/completions-capable model we want
    /// in the picker. Include prefixes `gpt*`/`chatgpt*` plus the `o`-series
    /// reasoning models (`o1`, `o3`, `o4-mini`, …: `o` followed by a digit);
    /// exclude the non-chat families above.
    public static func isChatCapable(_ id: String) -> Bool {
        let lower = id.lowercased()
        if excludeSubstrings.contains(where: { lower.contains($0) }) { return false }
        if includePrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let chars = Array(lower)
        // o-series: "o" immediately followed by a digit.
        return chars.count >= 2 && chars[0] == "o" && chars[1].isNumber
    }

    public static func parse(_ data: Data) -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let models = decoded.data else { return [] }
        var seen = Set<String>()
        let ids = models.map(\.id).filter { isChatCapable($0) && seen.insert($0).inserted }
        // Newest-looking first: reverse lexicographic puts gpt-5 above gpt-4o
        // above gpt-4, and the o-series above gpt-*. Approximate but stable.
        return Array(ids.sorted(by: >).prefix(cap))
    }
}

/// Anthropic `GET https://api.anthropic.com/v1/models`. Every returned model is a
/// chat model, so no filtering — keep the server's order (newest first).
public enum AnthropicModelList {
    public static func parse(_ data: Data) -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let models = decoded.data else { return [] }
        var seen = Set<String>()
        return models.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Gemini `GET https://generativelanguage.googleapis.com/v1beta/models?key=…`.
/// Keep only models whose `supportedGenerationMethods` includes `generateContent`
/// (the method `GeminiClient` calls), strip the `models/` name prefix, and drop
/// the embedding / attributed-QA (`aqa`) helpers. Server order preserved.
public enum GeminiModelList {
    static let excludeSubstrings = ["embedding", "aqa", "gecko"]

    public static func parse(_ data: Data) -> [String] {
        struct Response: Decodable {
            struct Model: Decodable {
                let name: String?
                let supportedGenerationMethods: [String]?
            }
            let models: [Model]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let models = decoded.models else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for model in models {
            guard let name = model.name,
                  (model.supportedGenerationMethods ?? []).contains("generateContent") else { continue }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            let lower = id.lowercased()
            guard !excludeSubstrings.contains(where: { lower.contains($0) }) else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}

/// Ollama `GET {base}/api/tags` — the models actually installed locally. Returns
/// the bare tag names (e.g. `llama3.2:latest`); the `ollama:` picker prefix is
/// added downstream. Server order preserved.
public enum OllamaModelList {
    public static func parse(_ data: Data) -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let name: String? }
            let models: [Model]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let models = decoded.models else { return [] }
        var seen = Set<String>()
        return models.compactMap(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
