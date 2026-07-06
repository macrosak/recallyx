import Foundation
import Testing
@testable import RecallyxCore

// MARK: - Hermetic seams

/// A fetcher returning one canned list for every provider, counting calls so the
/// TTL/in-flight skip logic can be asserted.
private actor CountingFetcher: ModelListFetching {
    private(set) var calls = 0
    private let result: [String]?
    init(result: [String]?) { self.result = result }
    func fetchModels(for provider: ProviderConfig) async -> [String]? {
        calls += 1
        return result
    }
    func callCount() -> Int { calls }
}

/// Mutable clock reference so a test can advance time past the TTL.
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@Suite("LiveModelCatalog")
struct LiveModelCatalogTests {
    // MARK: - Pure live-aware grouping (ModelCatalog.groups(forProviders:liveModels:))

    @Test func liveOpenAIListReplacesHardcoded() {
        let p = ProviderConfig(type: .openai)
        let groups = ModelCatalog.groups(forProviders: [p], liveModels: [p.id: ["gpt-9", "gpt-8"]])
        #expect(groups.count == 1)
        #expect(groups[0].models == ["gpt-9", "gpt-8"])
        #expect(groups[0].models != ModelCatalog.openAI)
    }

    @Test func liveOllamaGetsRoutingPrefix() {
        let p = ProviderConfig(type: .ollama)
        let groups = ModelCatalog.groups(forProviders: [p], liveModels: [p.id: ["llama3.2:latest", "llava:13b"]])
        #expect(groups[0].models == ["ollama:llama3.2:latest", "ollama:llava:13b"])
        for model in groups[0].models { #expect(AIProvider.provider(for: model) == .ollama) }
    }

    @Test func liveCustomModelsGetNamespace() {
        let id = UUID()
        let p = ProviderConfig(id: id, type: .openAICompatible, displayName: "Groq",
                               baseURL: "https://api.groq.com/openai/v1", models: ["manual-only"])
        // Live list wins over the manual list, tagged custom:<id>:.
        let groups = ModelCatalog.groups(forProviders: [p], liveModels: [id: ["llama-3.1-70b", "mixtral-8x7b"]])
        #expect(groups[0].models == [
            "custom:\(id.uuidString.lowercased()):llama-3.1-70b",
            "custom:\(id.uuidString.lowercased()):mixtral-8x7b",
        ])
        for model in groups[0].models { #expect(AIProvider.provider(for: model) == .openAICompatible) }
    }

    @Test func providerAbsentFromLiveMapFallsBackToHardcoded() {
        let openai = ProviderConfig(type: .openai)
        let gemini = ProviderConfig(type: .gemini)
        // Only openai has a live list; gemini falls back to the catalog.
        let groups = ModelCatalog.groups(forProviders: [openai, gemini], liveModels: [openai.id: ["gpt-9"]])
        #expect(groups[0].models == ["gpt-9"])
        #expect(groups[1].models == ModelCatalog.gemini)
    }

    @Test func emptyLiveListFallsBackToHardcoded() {
        let p = ProviderConfig(type: .anthropic)
        let groups = ModelCatalog.groups(forProviders: [p], liveModels: [p.id: []])
        #expect(groups[0].models == ModelCatalog.anthropic)
    }

    @Test func emptyLiveModelsMapMatchesStaticGrouping() {
        let providers = [ProviderConfig(type: .openai), ProviderConfig(type: .ollama)]
        #expect(ModelCatalog.groups(forProviders: providers, liveModels: [:]).map(\.models)
            == ModelCatalog.groups(forProviders: providers).map(\.models))
    }

    // MARK: - fetchNow + TTL + fallback

    @Test @MainActor func fetchNowStoresAndGroupsGoLive() async {
        let fetcher = CountingFetcher(result: ["gpt-9", "gpt-8"])
        let catalog = LiveModelCatalog(ttl: 3600, service: fetcher)
        let p = ProviderConfig(type: .openai)

        // Before any fetch → fallback.
        #expect(catalog.groups(for: [p])[0].models == ModelCatalog.openAI)

        let stored = await catalog.fetchNow(p)
        #expect(stored)
        #expect(catalog.groups(for: [p])[0].models == ["gpt-9", "gpt-8"])
    }

    @Test @MainActor func expiredEntryFallsBackToHardcoded() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let fetcher = CountingFetcher(result: ["gpt-9"])
        let catalog = LiveModelCatalog(ttl: 60, now: { clock.date }, service: fetcher)
        let p = ProviderConfig(type: .openai)

        await catalog.fetchNow(p)
        #expect(catalog.groups(for: [p])[0].models == ["gpt-9"])

        // Advance past the TTL → the entry is stale → fallback.
        clock.date = clock.date.addingTimeInterval(120)
        #expect(catalog.groups(for: [p])[0].models == ModelCatalog.openAI)
    }

    @Test @MainActor func failedFetchLeavesNoEntry() async {
        let fetcher = CountingFetcher(result: nil) // simulates network/key failure
        let catalog = LiveModelCatalog(service: fetcher)
        let p = ProviderConfig(type: .gemini)

        let stored = await catalog.fetchNow(p)
        #expect(!stored)
        #expect(catalog.groups(for: [p])[0].models == ModelCatalog.gemini)
    }

    @Test @MainActor func appleIsNotFetchable() async {
        let fetcher = CountingFetcher(result: ["should-not-be-used"])
        let catalog = LiveModelCatalog(service: fetcher)
        let apple = ProviderConfig(type: .apple)

        let stored = await catalog.fetchNow(apple)
        #expect(!stored)
        #expect(await fetcher.callCount() == 0)
        #expect(catalog.groups(for: [apple])[0].models == ModelCatalog.apple)
    }

    @Test @MainActor func freshEntrySkipsRefetchUnlessForced() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let fetcher = CountingFetcher(result: ["gpt-9"])
        let catalog = LiveModelCatalog(ttl: 3600, now: { clock.date }, service: fetcher)
        let p = ProviderConfig(type: .openai)

        await catalog.fetchNow(p)
        #expect(await fetcher.callCount() == 1)

        // Within TTL, non-forced → skipped.
        let second = await catalog.fetchNow(p)
        #expect(!second)
        #expect(await fetcher.callCount() == 1)

        // Forced → refetches even within the TTL.
        let forced = await catalog.fetchNow(p, force: true)
        #expect(forced)
        #expect(await fetcher.callCount() == 2)
    }
}
