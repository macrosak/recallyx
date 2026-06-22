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
        let expected = [
            "ollama:llama3.2", "ollama:qwen2.5", "ollama:mistral",
            "ollama:llava", "ollama:llama3.2-vision",
        ]
        #expect(ModelCatalog.ollama == expected)
        for model in ModelCatalog.ollama {
            #expect(AIProvider.provider(for: model) == .ollama)
        }
        // The two vision-capable locals are surfaced for the pickers.
        #expect(AIProvider.isOllamaVisionModel("ollama:llava"))
        #expect(AIProvider.isOllamaVisionModel("ollama:llama3.2-vision"))
    }

    @Test func appleModelsPresentAndRouteToApple() {
        #expect(ModelCatalog.apple == ["apple:on-device"])
        for model in ModelCatalog.apple {
            #expect(AIProvider.provider(for: model) == .apple)
        }
        #expect(ModelCatalog.all.contains("apple:on-device"))
    }

    // MARK: - groups(openAI:anthropic:ollama:apple:) — pure, flag-driven

    @Test func groupsAllTrueAreFourInOrderWithRightModels() {
        let groups = ModelCatalog.groups(openAI: true, anthropic: true, ollama: true, apple: true)
        #expect(groups.count == 4)
        #expect(groups.map(\.title) == ["OpenAI", "Anthropic", "Ollama (local)", "Apple Intelligence (on-device)"])
        #expect(groups[0].models == ModelCatalog.openAI)
        #expect(groups[1].models == ModelCatalog.anthropic)
        #expect(groups[2].models == ModelCatalog.ollama)
        #expect(groups[3].models == ModelCatalog.apple)
    }

    @Test func groupsOnlyOpenAIIsJustOpenAI() {
        let groups = ModelCatalog.groups(openAI: true, anthropic: false, ollama: false, apple: false)
        #expect(groups.map(\.title) == ["OpenAI"])
        #expect(groups.first?.models == ModelCatalog.openAI)
    }

    @Test func groupsAnthropicFalseHasNoAnthropicGroup() {
        let groups = ModelCatalog.groups(openAI: true, anthropic: false, ollama: true, apple: true)
        #expect(!groups.contains { $0.title == "Anthropic" })
        #expect(groups.map(\.title) == ["OpenAI", "Ollama (local)", "Apple Intelligence (on-device)"])
    }

    @Test func groupsAllFalseIsEmpty() {
        #expect(ModelCatalog.groups(openAI: false, anthropic: false, ollama: false, apple: false).isEmpty)
    }

    // MARK: - groupsPreservingSelection — keeps the Picker selection visible

    @Test func selectionInAGroupIsNotDuplicated() {
        let base = ModelCatalog.groups(openAI: true, anthropic: false, ollama: true, apple: false)
        let result = ModelCatalog.groupsPreservingSelection(base, selected: ModelCatalog.openAI[0])
        #expect(result.map(\.title) == base.map(\.title))
        #expect(!result.contains { $0.title == "Configured" })
    }

    @Test func unavailableSelectionGetsTrailingConfiguredGroup() {
        let base = ModelCatalog.groups(openAI: true, anthropic: false, ollama: true, apple: false)
        let result = ModelCatalog.groupsPreservingSelection(base, selected: "claude-sonnet-4-6")
        #expect(result.count == base.count + 1)
        #expect(result.last?.title == "Configured")
        #expect(result.last?.models == ["claude-sonnet-4-6"])
    }

    @Test func emptySelectionIsLeftUntouched() {
        let base = ModelCatalog.groups(openAI: true, anthropic: true, ollama: true, apple: true)
        let result = ModelCatalog.groupsPreservingSelection(base, selected: "")
        #expect(result.map(\.title) == base.map(\.title))
    }

    @Test func emptyGroupsWithSelectionYieldsOnlyConfigured() {
        let result = ModelCatalog.groupsPreservingSelection([], selected: "gpt-4o")
        #expect(result.map(\.title) == ["Configured"])
        #expect(result.first?.models == ["gpt-4o"])
    }
}
