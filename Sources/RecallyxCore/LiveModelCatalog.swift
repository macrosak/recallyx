import Foundation

/// Fetches a provider's real, current model list from its API. The default
/// `ModelListService` does the URLSession call (untested — network); tests inject
/// a hermetic fake. All results are **bare, provider-native** ids (Ollama tag
/// names without the `ollama:` prefix, custom ids without the `custom:<id>:`
/// wrapper) — namespacing is applied in `ModelCatalog.groups(forProviders:liveModels:)`.
public protocol ModelListFetching: Sendable {
    /// Returns the provider's live model ids, or `nil` on any failure (network,
    /// bad/absent key, non-2xx, unparseable body) so the caller falls back to the
    /// hardcoded catalog. Never throws.
    func fetchModels(for provider: ProviderConfig) async -> [String]?
}

/// Production fetcher: reads the provider's API key from the Keychain (cloud +
/// custom) and hits its list-models endpoint via `URLSession`. Runs off the main
/// actor (called from a background `Task`), only ever on an explicit user action
/// (opening Settings / saving a key) — never at launch.
public struct ModelListService: ModelListFetching {
    public init() {}

    private static let timeout: TimeInterval = 15

    public func fetchModels(for provider: ProviderConfig) async -> [String]? {
        switch provider.type {
        case .openai:
            guard let key = KeychainStore.openAIKey.read(), !key.isEmpty else { return nil }
            return await fetchOpenAICompatible(baseURL: OpenAIClient.defaultBaseURL, key: key)
        case .anthropic:
            guard let key = KeychainStore.anthropicKey.read(), !key.isEmpty else { return nil }
            return await fetchAnthropic(key: key)
        case .gemini:
            guard let key = KeychainStore.geminiKey.read(), !key.isEmpty else { return nil }
            return await fetchGemini(key: key)
        case .ollama:
            let base = (provider.baseURL?.isEmpty == false) ? provider.baseURL! : recallyxDefaultOllamaBaseURL
            return await fetchOllama(baseURL: base)
        case .openAICompatible:
            guard let base = provider.baseURL, !base.isEmpty else { return nil }
            let account = provider.keychainAccount ?? ProviderConfig.customKeychainAccount(for: provider.id)
            // Many OpenAI-compatible servers require a key; some (local) don't —
            // send it when present, but an empty key still tries the endpoint.
            let key = KeychainStore.custom(account: account).read() ?? ""
            return await fetchOpenAICompatible(baseURL: base, key: key)
        case .apple:
            return nil
        }
    }

    private func fetchOpenAICompatible(baseURL: String, key: String) async -> [String]? {
        guard let url = OpenAIClient.modelsListURL(baseURL: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let data = await Self.get(request) else { return nil }
        let models = OpenAIModelList.parse(data)
        return models.isEmpty ? nil : models
    }

    private func fetchAnthropic(key: String) async -> [String]? {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let data = await Self.get(request) else { return nil }
        let models = AnthropicModelList.parse(data)
        return models.isEmpty ? nil : models
    }

    private func fetchGemini(key: String) async -> [String]? {
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(encoded)&pageSize=200")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        guard let data = await Self.get(request) else { return nil }
        let models = GeminiModelList.parse(data)
        return models.isEmpty ? nil : models
    }

    private func fetchOllama(baseURL: String) async -> [String]? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: "\(base)/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        guard let data = await Self.get(request) else { return nil }
        let models = OllamaModelList.parse(data)
        return models.isEmpty ? nil : models
    }

    /// One GET, returning the body only on a 2xx. Any error → nil (fall back).
    private static func get(_ request: URLRequest) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}

/// Holds the fetched-and-fresh model lists per provider and hands the pickers a
/// live (or fallback) grouping. `@MainActor ObservableObject` so a completing
/// fetch republishes and any open Settings picker updates. Entries carry a
/// timestamp and expire after `ttl` (~1h) — an expired provider silently falls
/// back to the hardcoded `ModelCatalog` until the next refresh. Injectable
/// `service` + `now` clock keep the TTL/fallback logic hermetically testable.
@MainActor
public final class LiveModelCatalog: ObservableObject {
    public struct Entry: Equatable {
        public var models: [String]
        public var fetchedAt: Date
        public init(models: [String], fetchedAt: Date) {
            self.models = models
            self.fetchedAt = fetchedAt
        }
    }

    @Published public private(set) var entries: [UUID: Entry] = [:]

    private let ttl: TimeInterval
    private let now: () -> Date
    private let service: ModelListFetching
    /// In-flight provider ids, so a repeated refresh doesn't double-fetch.
    private var inFlight: Set<UUID> = []

    public init(
        ttl: TimeInterval = 3600,
        now: @escaping () -> Date = Date.init,
        service: ModelListFetching = ModelListService()
    ) {
        self.ttl = ttl
        self.now = now
        self.service = service
    }

    /// Only these provider types have a fetchable model list; Apple is static.
    public static func isFetchable(_ type: ProviderType) -> Bool {
        switch type {
        case .openai, .anthropic, .gemini, .ollama, .openAICompatible: return true
        case .apple: return false
        }
    }

    /// The non-expired fetched lists (bare ids), keyed by provider id — the
    /// `liveModels` input for the pure grouping.
    public func freshModels(asOf time: Date? = nil) -> [UUID: [String]] {
        let t = time ?? now()
        var out: [UUID: [String]] = [:]
        for (id, entry) in entries where !entry.models.isEmpty && t.timeIntervalSince(entry.fetchedAt) < ttl {
            out[id] = entry.models
        }
        return out
    }

    /// The picker groups for `providers`: a provider with a fresh fetched list
    /// uses it; every other provider falls back to the hardcoded catalog.
    public func groups(for providers: [ProviderConfig]) -> [ModelCatalog.ModelGroup] {
        ModelCatalog.groups(forProviders: providers, liveModels: freshModels())
    }

    /// Fire-and-forget refresh of every eligible enabled provider. Fetches run in
    /// the background; results republish `entries` as they land. A provider with a
    /// still-fresh entry is skipped unless `force` (used after a key/URL save).
    public func refresh(providers: [ProviderConfig], force: Bool = false) {
        for provider in providers where provider.enabled && Self.isFetchable(provider.type) {
            Task { [weak self] in await self?.fetchNow(provider, force: force) }
        }
    }

    /// Awaitable single-provider fetch + store — the core `refresh` builds on, and
    /// what tests drive directly. Returns whether a fresh list was stored. No-op
    /// (returns false) when the provider isn't fetchable, is already in flight, or
    /// has a still-fresh entry and `force` is off, or the fetch yields nothing.
    @discardableResult
    public func fetchNow(_ provider: ProviderConfig, force: Bool = false) async -> Bool {
        guard Self.isFetchable(provider.type) else { return false }
        let id = provider.id
        if inFlight.contains(id) { return false }
        if !force, let entry = entries[id], now().timeIntervalSince(entry.fetchedAt) < ttl { return false }
        inFlight.insert(id)
        let models = await service.fetchModels(for: provider)
        inFlight.remove(id)
        guard let models, !models.isEmpty else { return false }
        entries[id] = Entry(models: models, fetchedAt: now())
        return true
    }
}
