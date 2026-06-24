import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@Suite("ProviderConfig")
struct ProviderConfigTests {
    // MARK: - Round-trip

    @Test func roundTripsThroughCodable() throws {
        let configs: [ProviderConfig] = [
            ProviderConfig(type: .openai, keychainAccount: KeychainStore.openAIKey.account),
            ProviderConfig(type: .ollama, baseURL: "http://localhost:11434"),
            ProviderConfig(type: .apple),
            ProviderConfig(
                type: .openAICompatible,
                displayName: "Groq",
                baseURL: "https://api.groq.com/openai/v1",
                keychainAccount: "custom-x-api-key",
                models: ["llama-3.1-70b", "mixtral-8x7b"]
            ),
        ]
        let data = try JSONEncoder().encode(configs)
        let decoded = try JSONDecoder().decode([ProviderConfig].self, from: data)
        #expect(decoded == configs)
    }

    @Test func defaultDisplayNameMatchesType() {
        #expect(ProviderConfig(type: .openai).displayName == "OpenAI")
        #expect(ProviderConfig(type: .anthropic).displayName == "Anthropic")
        #expect(ProviderConfig(type: .gemini).displayName == "Google Gemini")
        #expect(ProviderConfig(type: .ollama).displayName == "Ollama (local)")
        #expect(ProviderConfig(type: .apple).displayName == "Apple Intelligence (on-device)")
        #expect(ProviderConfig(type: .openAICompatible).displayName == "Custom (OpenAI-compatible)")
    }

    @Test func customModelIDNamespacesByProviderID() {
        let id = UUID()
        let config = ProviderConfig(id: id, type: .openAICompatible)
        #expect(config.customModelID("gpt-4o") == "custom:\(id.uuidString.lowercased()):gpt-4o")
    }

    @Test func customKeychainAccountIsStableAndIDDerived() {
        let id = UUID()
        #expect(ProviderConfig.customKeychainAccount(for: id) == "custom-\(id.uuidString.lowercased())-api-key")
        // Stable across calls.
        #expect(ProviderConfig.customKeychainAccount(for: id) == ProviderConfig.customKeychainAccount(for: id))
    }

    // MARK: - Migration seeding (hermetic via injected flags)

    @Test func seedNoKeysGivesOnlyOllama() {
        let seeded = ProviderConfig.seedFromCurrentReality(
            hasOpenAIKey: false, hasAnthropicKey: false, hasGeminiKey: false,
            appleAvailable: false, ollamaBaseURL: "http://localhost:11434"
        )
        #expect(seeded.map(\.type) == [.ollama])
        #expect(seeded.first?.baseURL == "http://localhost:11434")
    }

    @Test func seedAllPresentGivesAllInPickerOrder() {
        let seeded = ProviderConfig.seedFromCurrentReality(
            hasOpenAIKey: true, hasAnthropicKey: true, hasGeminiKey: true,
            appleAvailable: true, ollamaBaseURL: "http://localhost:11434"
        )
        #expect(seeded.map(\.type) == [.openai, .anthropic, .gemini, .ollama, .apple])
        // Cloud entries reference their fixed keychain accounts.
        #expect(seeded[0].keychainAccount == KeychainStore.openAIKey.account)
        #expect(seeded[1].keychainAccount == KeychainStore.anthropicKey.account)
        #expect(seeded[2].keychainAccount == KeychainStore.geminiKey.account)
    }

    @Test func seedOnlyOpenAIKeyGivesOpenAIPlusOllama() {
        let seeded = ProviderConfig.seedFromCurrentReality(
            hasOpenAIKey: true, hasAnthropicKey: false, hasGeminiKey: false,
            appleAvailable: false
        )
        #expect(seeded.map(\.type) == [.openai, .ollama])
    }

    @Test func seedNeverSeedsCustom() {
        let seeded = ProviderConfig.seedFromCurrentReality(
            hasOpenAIKey: true, hasAnthropicKey: true, hasGeminiKey: true,
            appleAvailable: true
        )
        #expect(!seeded.contains { $0.type == .openAICompatible })
    }

    @Test func seededProvidersAreEnabled() {
        let seeded = ProviderConfig.seedFromCurrentReality(
            hasOpenAIKey: true, hasAnthropicKey: false, hasGeminiKey: false,
            appleAvailable: true
        )
        #expect(seeded.allSatisfy { $0.enabled })
    }
}
