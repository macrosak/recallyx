import Foundation
import Testing
@testable import RecallyxCore

@Suite("ModelListParsing")
struct ModelListParsingTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - OpenAI

    @Test func openAIKeepsChatModelsAndDropsNonChat() {
        let json = """
        {"object":"list","data":[
          {"id":"gpt-4o","object":"model"},
          {"id":"gpt-4o-mini","object":"model"},
          {"id":"o3","object":"model"},
          {"id":"o4-mini","object":"model"},
          {"id":"chatgpt-4o-latest","object":"model"},
          {"id":"text-embedding-3-small","object":"model"},
          {"id":"whisper-1","object":"model"},
          {"id":"tts-1","object":"model"},
          {"id":"dall-e-3","object":"model"},
          {"id":"gpt-image-1","object":"model"},
          {"id":"omni-moderation-latest","object":"model"},
          {"id":"gpt-4o-realtime-preview","object":"model"},
          {"id":"gpt-4o-audio-preview","object":"model"},
          {"id":"gpt-4o-search-preview","object":"model"},
          {"id":"gpt-3.5-turbo-instruct","object":"model"},
          {"id":"davinci-002","object":"model"}
        ]}
        """
        let models = OpenAIModelList.parse(data(json))
        let kept = Set(models)
        #expect(kept == ["gpt-4o", "gpt-4o-mini", "o3", "o4-mini", "chatgpt-4o-latest"])
        // Explicitly excluded families are gone.
        for banned in ["text-embedding-3-small", "whisper-1", "tts-1", "dall-e-3",
                       "gpt-image-1", "omni-moderation-latest", "gpt-4o-realtime-preview",
                       "gpt-4o-audio-preview", "gpt-4o-search-preview",
                       "gpt-3.5-turbo-instruct", "davinci-002"] {
            #expect(!kept.contains(banned))
        }
    }

    @Test func openAISortsReverseLexicographicAndCaps() {
        var entries: [String] = []
        for i in 0..<40 { entries.append("{\"id\":\"gpt-model-\(i)\"}") }
        let json = "{\"data\":[\(entries.joined(separator: ","))]}"
        let models = OpenAIModelList.parse(data(json))
        #expect(models.count == OpenAIModelList.cap)
        #expect(models == models.sorted(by: >))
    }

    @Test func openAIIsChatCapableSpotChecks() {
        #expect(OpenAIModelList.isChatCapable("gpt-4o"))
        #expect(OpenAIModelList.isChatCapable("o1"))
        #expect(OpenAIModelList.isChatCapable("o4-mini"))
        #expect(OpenAIModelList.isChatCapable("chatgpt-4o-latest"))
        #expect(!OpenAIModelList.isChatCapable("text-embedding-3-large"))
        #expect(!OpenAIModelList.isChatCapable("dall-e-3"))
        #expect(!OpenAIModelList.isChatCapable("gpt-3.5-turbo-instruct"))
        #expect(!OpenAIModelList.isChatCapable("omni-1")) // o + non-digit → not o-series
    }

    @Test func openAIGarbageYieldsEmpty() {
        #expect(OpenAIModelList.parse(data("not json")).isEmpty)
        #expect(OpenAIModelList.parse(data("{}")).isEmpty)
        #expect(OpenAIModelList.parse(Data()).isEmpty)
    }

    // MARK: - Anthropic

    @Test func anthropicKeepsAllInOrder() {
        let json = """
        {"data":[
          {"type":"model","id":"claude-opus-4-6","display_name":"Claude Opus 4.6"},
          {"type":"model","id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6"},
          {"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5"}
        ],"has_more":false}
        """
        #expect(AnthropicModelList.parse(data(json))
            == ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"])
    }

    @Test func anthropicGarbageYieldsEmpty() {
        #expect(AnthropicModelList.parse(data("[]")).isEmpty)
    }

    // MARK: - Gemini

    @Test func geminiKeepsGenerateContentStripsPrefixExcludesEmbedding() {
        let json = """
        {"models":[
          {"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
          {"name":"models/embedding-gecko-001","supportedGenerationMethods":["generateContent"]},
          {"name":"models/aqa","supportedGenerationMethods":["generateAnswer"]},
          {"name":"models/gemini-1.5-flash-vision","supportedGenerationMethods":["generateContent"]}
        ]}
        """
        let models = GeminiModelList.parse(data(json))
        #expect(models == ["gemini-3.5-flash", "gemini-2.5-pro", "gemini-1.5-flash-vision"])
        #expect(!models.contains { $0.contains("embedding") })
        #expect(!models.contains("aqa"))
    }

    @Test func geminiGarbageYieldsEmpty() {
        #expect(GeminiModelList.parse(data("{\"foo\":1}")).isEmpty)
    }

    // MARK: - Ollama

    @Test func ollamaReturnsBareTagNamesInOrder() {
        let json = """
        {"models":[
          {"name":"llama3.2:latest","model":"llama3.2:latest"},
          {"name":"qwen2.5:7b","model":"qwen2.5:7b"},
          {"name":"llava:13b","model":"llava:13b"}
        ]}
        """
        let models = OllamaModelList.parse(data(json))
        #expect(models == ["llama3.2:latest", "qwen2.5:7b", "llava:13b"])
        // Bare — no routing prefix yet (applied by ModelCatalog grouping).
        #expect(!models.contains { $0.hasPrefix("ollama:") })
    }

    @Test func ollamaGarbageYieldsEmpty() {
        #expect(OllamaModelList.parse(data("nope")).isEmpty)
    }
}
