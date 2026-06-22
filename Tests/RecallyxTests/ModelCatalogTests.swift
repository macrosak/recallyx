import Foundation
import Testing
@testable import Recallyx

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test func allIsOpenAIPlusAnthropicPlusOllamaPlusApple() {
        #expect(ModelCatalog.all == ModelCatalog.openAI + ModelCatalog.anthropic + ModelCatalog.ollama + ModelCatalog.apple)
    }

    @Test func defaultStaysOpenAI() {
        #expect(ModelCatalog.default == "gpt-4o-mini")
        #expect(ModelCatalog.openAI.contains(ModelCatalog.default))
    }

    @Test func claudeModelsPresentAndRouteToAnthropic() {
        let expected = ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-8"]
        #expect(ModelCatalog.anthropic == expected)
        for model in ModelCatalog.anthropic {
            #expect(AIProvider.provider(for: model) == .anthropic)
        }
    }

    @Test func haikuListedFirst() {
        #expect(ModelCatalog.anthropic.first == "claude-haiku-4-5")
    }

    @Test func openAIModelsRouteToOpenAI() {
        for model in ModelCatalog.openAI {
            #expect(AIProvider.provider(for: model) == .openai)
        }
    }

    @Test func ollamaModelsPresentAndRouteToOllama() {
        let expected = ["ollama:llama3.2", "ollama:qwen2.5", "ollama:mistral"]
        #expect(ModelCatalog.ollama == expected)
        for model in ModelCatalog.ollama {
            #expect(AIProvider.provider(for: model) == .ollama)
        }
    }

    @Test func appleModelsPresentAndRouteToApple() {
        #expect(ModelCatalog.apple == ["apple:on-device"])
        for model in ModelCatalog.apple {
            #expect(AIProvider.provider(for: model) == .apple)
        }
        #expect(ModelCatalog.all.contains("apple:on-device"))
    }
}
