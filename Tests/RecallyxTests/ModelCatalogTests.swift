import Foundation
import Testing
@testable import Recallyx

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test func allIsOpenAIPlusAnthropic() {
        #expect(ModelCatalog.all == ModelCatalog.openAI + ModelCatalog.anthropic)
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
}
