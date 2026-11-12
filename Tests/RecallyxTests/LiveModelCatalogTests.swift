import Foundation
import Testing
@testable import RecallyxCore

// MARK: - Hermetic seams

/// A fetcher returning one canned list for every provider, counting calls so the
/// TTL/in-flight skip logic can be asserted.
private actor CountingFetcher: ModelListFetching {
    private(set) var calls = 0
    private var result: Result<[String], ModelFetchError>
    init(result: [String]?) { self.result = result.map { .success($0) } ?? .failure(.network) }
    func set(_ r: Result<[String], ModelFetchError>) { result = r }
    func fetchModels(for provider: ProviderConfig) async -> Result<[String], ModelFetchError> {
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
        // The curated manual list wins over the fetched one.
        let curated = ModelCatalog.groups(forProviders: [p], liveModels: [id: ["llama-3.1-70b", "mixtral-8x7b"]])
        #expect(curated[0].models == ["custom:\(id.uuidString.lowercased()):manual-only"])

        // No curated ids → the fetched list, tagged custom:<id>:.
        var bare = p
        bare.models = []
        let groups = ModelCatalog.groups(forProviders: [bare], liveModels: [id: ["llama-3.1-70b", "mixtral-8x7b"]])
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

    @Test @MainActor func staleCachedListStillUsedPastTTL() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let fetcher = CountingFetcher(result: ["gpt-9"])
        let catalog = LiveModelCatalog(ttl: 60, now: { clock.date }, service: fetcher)
        let p = ProviderConfig(type: .openai)

        await catalog.fetchNow(p)
        // Past the TTL the cached list is still shown (offline-friendly); the TTL
        // only allows a non-forced refetch.
        clock.date = clock.date.addingTimeInterval(120)
        #expect(catalog.groups(for: [p])[0].models == ["gpt-9"])
        await fetcher.set(.success(["gpt-10"]))
        #expect(await catalog.fetchNow(p))
        #expect(catalog.groups(for: [p])[0].models == ["gpt-10"])
    }

    @Test @MainActor func failedRefetchKeepsPreviousListAndRecordsStatus() async {
        let fetcher = CountingFetcher(result: ["gpt-9"])
        let catalog = LiveModelCatalog(service: fetcher)
        let p = ProviderConfig(type: .openai)
        await catalog.fetchNow(p)

        await fetcher.set(.failure(.unauthorized))
        #expect(!(await catalog.fetchNow(p, force: true)))
        #expect(catalog.groups(for: [p])[0].models == ["gpt-9"])
        guard case .failed(.unauthorized, _)? = catalog.status[p.id] else {
            Issue.record("expected failed(.unauthorized)"); return
        }
        #expect(catalog.statusText(for: p).contains("keeping the last fetched list"))

        // A later success clears the failure.
        await fetcher.set(.success(["gpt-11"]))
        #expect(await catalog.fetchNow(p, force: true))
        #expect(catalog.status[p.id] == nil)
    }

    @Test @MainActor func seededFromCacheAndPersistsOnChange() async {
        let p = ProviderConfig(type: .anthropic)
        let seeded = [p.id: LiveModelCatalog.Entry(models: ["claude-x"], fetchedAt: Date())]
        var saved: [UUID: LiveModelCatalog.Entry]?
        let fetcher = CountingFetcher(result: ["claude-y"])
        let catalog = LiveModelCatalog(service: fetcher, initialEntries: seeded, onEntriesChanged: { saved = $0 })

        // Launch: cached list shown with no network.
        #expect(catalog.groups(for: [p])[0].models == ["claude-x"])
        #expect(await fetcher.callCount() == 0)

        // Fresh seed within TTL → non-forced refresh skips.
        #expect(!(await catalog.fetchNow(p)))
        #expect(await catalog.fetchNow(p, force: true))
        #expect(saved?[p.id]?.models == ["claude-y"])
    }

    @Test @MainActor func pruneDropsDeletedProviders() {
        let keep = ProviderConfig(type: .openai)
        let gone = ProviderConfig(type: .gemini)
        var saved: [UUID: LiveModelCatalog.Entry]?
        let catalog = LiveModelCatalog(
            service: CountingFetcher(result: nil),
            initialEntries: [
                keep.id: .init(models: ["a"], fetchedAt: Date()),
                gone.id: .init(models: ["b"], fetchedAt: Date()),
            ],
            onEntriesChanged: { saved = $0 }
        )
        catalog.prune(keeping: [keep])
        #expect(Set(catalog.entries.keys) == [keep.id])
        #expect(saved.map { Set($0.keys) } == [keep.id])
    }

    @Test func statusTextCases() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entry = LiveModelCatalog.Entry(models: ["a", "b"], fetchedAt: now.addingTimeInterval(-120))
        #expect(LiveModelCatalog.statusText(entry: nil, status: nil, now: now) == "Showing the built-in model list.")
        #expect(LiveModelCatalog.statusText(entry: entry, status: nil, now: now) == "2 models fetched 2 min ago.")
        #expect(LiveModelCatalog.statusText(entry: nil, status: .fetching, now: now) == "Fetching models…")
        #expect(LiveModelCatalog.statusText(entry: nil, status: .failed(.missingKey, at: now), now: now)
            == "Couldn't fetch models: no API key saved — using the built-in list.")
    }

    @Test func cacheRoundTripsThroughUserDefaults() throws {
        let suite = "rx-modelcache-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ModelListCache.load(from: defaults).isEmpty)
        let id = UUID()
        let entries = [id: LiveModelCatalog.Entry(models: ["m1", "m2"], fetchedAt: Date(timeIntervalSince1970: 42))]
        ModelListCache.save(entries, to: defaults)
        #expect(ModelListCache.load(from: defaults) == entries)

        // Malformed → empty, never throws.
        defaults.set(Data("nope".utf8), forKey: ModelListCache.storageKey)
        #expect(ModelListCache.load(from: defaults).isEmpty)
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
