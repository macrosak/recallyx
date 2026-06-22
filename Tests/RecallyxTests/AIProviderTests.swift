import Foundation
import Testing
@testable import Recallyx

@Suite("AIProvider")
struct AIProviderTests {
    @Test func routesClaudePrefixToAnthropic() {
        #expect(AIProvider.provider(for: "claude-haiku-4-5") == .anthropic)
        #expect(AIProvider.provider(for: "claude-sonnet-4-6") == .anthropic)
        #expect(AIProvider.provider(for: "claude-opus-4-8") == .anthropic)
    }

    @Test func routesGptAndUnknownToOpenAI() {
        #expect(AIProvider.provider(for: "gpt-4o-mini") == .openai)
        #expect(AIProvider.provider(for: "gpt-5.4") == .openai)
        #expect(AIProvider.provider(for: "some-future-model") == .openai)
        #expect(AIProvider.provider(for: "") == .openai)
    }

    @Test func routesOllamaPrefixToOllama() {
        #expect(AIProvider.provider(for: "ollama:llama3.2") == .ollama)
        #expect(AIProvider.provider(for: "ollama:qwen2.5") == .ollama)
        #expect(AIProvider.provider(for: "ollama:mistral") == .ollama)
        // A custom override the user typed.
        #expect(AIProvider.provider(for: "ollama:deepseek-r1:7b") == .ollama)
    }

    @Test func routingIsCaseInsensitive() {
        #expect(AIProvider.provider(for: "Claude-Opus-4-8") == .anthropic)
        #expect(AIProvider.provider(for: "CLAUDE-haiku-4-5") == .anthropic)
        #expect(AIProvider.provider(for: "Ollama:Llama3.2") == .ollama)
        #expect(AIProvider.provider(for: "OLLAMA:mistral") == .ollama)
    }

    @Test func ollamaStripsRoutingPrefix() {
        #expect(OllamaClient.strippedModel("ollama:llama3.2") == "llama3.2")
        #expect(OllamaClient.strippedModel("OLLAMA:mistral") == "mistral")
        #expect(OllamaClient.strippedModel("ollama:deepseek-r1:7b") == "deepseek-r1:7b")
        // Bare names (no prefix) pass through unchanged.
        #expect(OllamaClient.strippedModel("llama3.2") == "llama3.2")
    }

    @Test func keychainMatchesProvider() {
        #expect(AIProvider.openai.keychain?.account == KeychainStore.openAIKey.account)
        #expect(AIProvider.anthropic.keychain?.account == KeychainStore.anthropicKey.account)
        // Local Ollama has no keychain key.
        #expect(AIProvider.ollama.keychain == nil)
    }

    @Test func displayNameNamesProvider() {
        #expect(AIProvider.openai.displayName == "OpenAI")
        #expect(AIProvider.anthropic.displayName == "Anthropic")
        #expect(AIProvider.ollama.displayName == "Ollama")
    }

    /// The injected `runAI` closure path is unaffected by the facade: a runner
    /// constructed with a stub never touches a real client or the keychain.
    @MainActor
    @Test func injectedRunAI_bypassesFacade() async throws {
        let runner = ActionRunner(
            defaultModel: { "claude-opus-4-8" },
            runScript: { script, input in "\(input)|\(script)" },
            runAI: { prompt, model, input, _ in "\(input)|ai(\(model ?? "default"):\(prompt))" }
        )
        let action = Action(name: "A", icon: "x", steps: [Step(type: .ai, prompt: "fix")])
        let out = try await runner.run(action, on: "seed")
        #expect(out == "seed|ai(default:fix)")
    }

    /// Cloud providers can take image input; a non-vision provider would not.
    /// `AIClient.complete` rejects `imageData` only for non-vision providers.
    @Test func cloudProvidersSupportVision() {
        #expect(AIProvider.openai.supportsVision == true)
        #expect(AIProvider.anthropic.supportsVision == true)
    }

    /// The image run path carries `imageData` into the AI step's seam for the
    /// first step and clears it for subsequent (text) steps.
    @MainActor
    @Test func imagePath_routesImageDataThroughSeam() async throws {
        var firstHadImage = false
        let runner = ActionRunner(
            defaultModel: { "gpt-4o-mini" },
            runScript: { script, input in "\(input)|\(script)" },
            runAI: { prompt, _, _, imageData in
                if prompt == "ocr" { firstHadImage = imageData != nil; return "text" }
                return "done"
            }
        )
        let action = Action(name: "A", icon: "x", steps: [Step(type: .ai, prompt: "ocr")])
        let out = try await runner.run(action, onImageData: Data([0xFF]))
        #expect(firstHadImage == true)
        #expect(out == "text")
    }
}
