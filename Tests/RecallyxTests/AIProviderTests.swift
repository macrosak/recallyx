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

    @Test func routingIsCaseInsensitive() {
        #expect(AIProvider.provider(for: "Claude-Opus-4-8") == .anthropic)
        #expect(AIProvider.provider(for: "CLAUDE-haiku-4-5") == .anthropic)
    }

    @Test func keychainMatchesProvider() {
        #expect(AIProvider.openai.keychain.account == KeychainStore.openAIKey.account)
        #expect(AIProvider.anthropic.keychain.account == KeychainStore.anthropicKey.account)
    }

    @Test func displayNameNamesProvider() {
        #expect(AIProvider.openai.displayName == "OpenAI")
        #expect(AIProvider.anthropic.displayName == "Anthropic")
    }

    /// The injected `runAI` closure path is unaffected by the facade: a runner
    /// constructed with a stub never touches a real client or the keychain.
    @MainActor
    @Test func injectedRunAI_bypassesFacade() async throws {
        let runner = ActionRunner(
            defaultModel: { "claude-opus-4-8" },
            runScript: { script, input in "\(input)|\(script)" },
            runAI: { prompt, model, input in "\(input)|ai(\(model ?? "default"):\(prompt))" }
        )
        let action = Action(name: "A", icon: "x", steps: [Step(type: .ai, prompt: "fix")])
        let out = try await runner.run(action, on: "seed")
        #expect(out == "seed|ai(default:fix)")
    }
}
