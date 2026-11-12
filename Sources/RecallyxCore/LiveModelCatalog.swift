import Foundation

// MARK: - Fetch errors

/// Why a model-list fetch failed — a **content-free** category (never a key,
/// never a response body), safe to log and to show in the Providers tab.
public enum ModelFetchError: Error, Equatable, Sendable {
    /// Cloud provider without a saved API key.
    case missingKey
    /// Custom/Ollama provider without a usable base URL.
    case missingBaseURL
    /// Transport failure (offline, DNS, refused, timeout — e.g. Ollama not running).
    case network
    /// 401/403 — the key was rejected.
    case unauthorized
    /// Any other non-2xx status.
    case http(Int)
    /// 2xx but the body wasn't the expected JSON.
    case unparseable
    /// Parsed fine but no usable (chat) models came back.
    case empty
    /// Apple — on-device, static, nothing to fetch.
    case notFetchable

    /// Short, user-facing explanation for the status line.
    public var message: String {
        switch self {
        case .missingKey: return "no API key saved"
        case .missingBaseURL: return "no base URL set"
        case .network: return "couldn't reach the server"
        case .unauthorized: return "API key rejected"
        case .http(let code): return "server returned HTTP \(code)"
        case .unparseable: return "unexpected response"
        case .empty: return "no chat models returned"
        case .notFetchable: return "nothing to fetch"
        }
    }

    /// Log-safe category string.
    public var category: String {
        switch self {
        case .http(let code): return "http\(code)"
        default: return String(describing: self)
        }
    }
}

// MARK: - Fetching

/// Fetches a provider's real, current model list from its API. Results are
/// **bare, provider-native** ids (Ollama tag names without the `ollama:` prefix,
/// custom ids without the `custom:<id>:` wrapper) — namespacing is applied in
/// `ModelCatalog.groups(forProviders:liveModels:)`. Never throws.
public protocol ModelListFetching: Sendable {
    func fetchModels(for provider: ProviderConfig) async -> Result<[String], ModelFetchError>
}

/// Production fetcher: reads the provider's API key (cloud + custom) and hits its
/// list-models endpoint, following pagination (Anthropic `after_id`, Gemini
/// `pageToken`). Both the key lookup and the HTTP GET are injectable so the
/// request shapes + pagination are hermetically testable.
public struct ModelListService: ModelListFetching {
    public typealias HTTPGet = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias KeyLookup = @Sendable (ProviderConfig) -> String?

    private let readKey: KeyLookup
    private let get: HTTPGet

    static let timeout: TimeInterval = 15
    /// Safety bound on pagination loops (a misbehaving server can't spin us).
    static let maxPages = 10

    public init(
        readKey: @escaping KeyLookup = ModelListService.keychainKey,
        get: @escaping HTTPGet = { try await URLSession.shared.data(for: $0) }
    ) {
        self.readKey = readKey
        self.get = get
    }

    /// Default key lookup: the provider's Keychain item.
    public static let keychainKey: KeyLookup = { provider in
        switch provider.type {
        case .openai: return KeychainStore.openAIKey.read()
        case .anthropic: return KeychainStore.anthropicKey.read()
        case .gemini: return KeychainStore.geminiKey.read()
        case .openAICompatible:
            let account = provider.keychainAccount ?? ProviderConfig.customKeychainAccount(for: provider.id)
            return KeychainStore.custom(account: account).read()
        case .ollama, .apple: return nil
        }
    }

    public func fetchModels(for provider: ProviderConfig) async -> Result<[String], ModelFetchError> {
        let key = (readKey(provider) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider.type {
        case .openai:
            guard !key.isEmpty else { return .failure(.missingKey) }
            return await fetchOpenAIShape(baseURL: OpenAIClient.defaultBaseURL, key: key, parse: OpenAIModelList.parse)
        case .openAICompatible:
            guard let base = provider.baseURL, !base.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(.missingBaseURL)
            }
            // Many OpenAI-compatible servers need a key; local ones (LM Studio,
            // vLLM) don't — send it only when present.
            return await fetchOpenAIShape(baseURL: base, key: key, parse: OpenAICompatibleModelList.parse)
        case .anthropic:
            guard !key.isEmpty else { return .failure(.missingKey) }
            return await fetchAnthropic(key: key)
        case .gemini:
            guard !key.isEmpty else { return .failure(.missingKey) }
            return await fetchGemini(key: key)
        case .ollama:
            let base = (provider.baseURL?.isEmpty == false) ? provider.baseURL! : recallyxDefaultOllamaBaseURL
            return await fetchOllama(baseURL: base)
        case .apple:
            return .failure(.notFetchable)
        }
    }

    private func fetchOpenAIShape(baseURL: String, key: String, parse: (Data) -> [String]) async -> Result<[String], ModelFetchError> {
        guard let url = OpenAIClient.modelsListURL(baseURL: baseURL) else { return .failure(.missingBaseURL) }
        var request = Self.request(url)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return await body(request).flatMap { data in
            guard Self.looksLikeJSONObject(data) else { return .failure(.unparseable) }
            return Self.nonEmpty(parse(data))
        }
    }

    private func fetchAnthropic(key: String) async -> Result<[String], ModelFetchError> {
        var all: [String] = []
        var afterID: String?
        for _ in 0..<Self.maxPages {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = items
            var request = Self.request(components.url!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            switch await body(request) {
            case .failure(let error): return .failure(error)
            case .success(let data):
                guard let page = AnthropicModelList.parsePage(data) else { return .failure(.unparseable) }
                all += page.ids
                guard let next = page.nextAfterID else { return Self.nonEmpty(Self.dedupe(all)) }
                afterID = next
            }
        }
        return Self.nonEmpty(Self.dedupe(all))
    }

    private func fetchGemini(key: String) async -> Result<[String], ModelFetchError> {
        var all: [String] = []
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            var items = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            switch await body(Self.request(components.url!)) {
            case .failure(let error): return .failure(error)
            case .success(let data):
                guard let page = GeminiModelList.parsePage(data) else { return .failure(.unparseable) }
                all += page.ids
                guard let next = page.nextPageToken else { return Self.nonEmpty(Self.dedupe(all)) }
                pageToken = next
            }
        }
        return Self.nonEmpty(Self.dedupe(all))
    }

    private func fetchOllama(baseURL: String) async -> Result<[String], ModelFetchError> {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard !base.isEmpty, let url = URL(string: "\(base)/api/tags") else { return .failure(.missingBaseURL) }
        return await body(Self.request(url)).flatMap { data in
            guard Self.looksLikeJSONObject(data) else { return .failure(.unparseable) }
            return Self.nonEmpty(OllamaModelList.parse(data))
        }
    }

    // MARK: Helpers

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return request
    }

    /// One GET → the body on a 2xx, else a content-free error category.
    private func body(_ request: URLRequest) async -> Result<Data, ModelFetchError> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await get(request)
        } catch {
            return .failure(.network)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.unparseable) }
        switch http.statusCode {
        case 200..<300: return .success(data)
        case 401, 403: return .failure(.unauthorized)
        default: return .failure(.http(http.statusCode))
        }
    }

    private static func looksLikeJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private static func nonEmpty(_ ids: [String]) -> Result<[String], ModelFetchError> {
        ids.isEmpty ? .failure(.empty) : .success(ids)
    }

    private static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Persistent cache

/// Persists the fetched lists in UserDefaults (next to the app's settings blob,
/// under its own key so a fetch never churns the settings `onChange` path), keyed
/// by provider id. Lets the pickers show the last-fetched lists at launch and
/// offline — no network at launch. Tolerant: absent/malformed → empty cache.
public enum ModelListCache {
    public static let storageKey = "modelListCache.v1"

    public static func load(from defaults: UserDefaults = .standard) -> [UUID: LiveModelCatalog.Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: LiveModelCatalog.Entry].self, from: data)
        else { return [:] }
        var out: [UUID: LiveModelCatalog.Entry] = [:]
        for (key, entry) in raw {
            if let id = UUID(uuidString: key), !entry.models.isEmpty { out[id] = entry }
        }
        return out
    }

    public static func save(_ entries: [UUID: LiveModelCatalog.Entry], to defaults: UserDefaults = .standard) {
        let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Catalog

/// Holds the fetched model lists per provider and hands the pickers a live (or
/// fallback) grouping. `@MainActor ObservableObject` so a completing fetch
/// republishes and any open Settings picker updates.
///
/// **Cache semantics:** a fetched list is used for as long as it's cached —
/// including offline and across launches (seeded from `initialEntries`, persisted
/// via `onEntriesChanged`). `ttl` only throttles *re-fetching* (a non-forced
/// refresh skips a provider fetched within it). A provider never fetched, or
/// whose fetch failed with nothing cached, falls back to the hardcoded
/// `ModelCatalog`. A failed refetch keeps the previous cached list.
@MainActor
public final class LiveModelCatalog: ObservableObject {
    public struct Entry: Codable, Equatable, Sendable {
        public var models: [String]
        public var fetchedAt: Date
        public init(models: [String], fetchedAt: Date) {
            self.models = models
            self.fetchedAt = fetchedAt
        }
    }

    /// Per-provider fetch state for the Providers tab status line (in-memory).
    public enum Status: Equatable {
        case fetching
        case failed(ModelFetchError, at: Date)
    }

    @Published public private(set) var entries: [UUID: Entry]
    @Published public private(set) var status: [UUID: Status] = [:]

    private let ttl: TimeInterval
    private let now: () -> Date
    private let service: ModelListFetching
    private let onEntriesChanged: ([UUID: Entry]) -> Void
    /// In-flight provider ids, so a repeated refresh doesn't double-fetch.
    private var inFlight: Set<UUID> = []

    public init(
        ttl: TimeInterval = 3600,
        now: @escaping () -> Date = Date.init,
        service: ModelListFetching = ModelListService(),
        initialEntries: [UUID: Entry] = [:],
        onEntriesChanged: @escaping ([UUID: Entry]) -> Void = { _ in }
    ) {
        self.ttl = ttl
        self.now = now
        self.service = service
        self.entries = initialEntries
        self.onEntriesChanged = onEntriesChanged
    }

    /// Only these provider types have a fetchable model list; Apple is static.
    public static func isFetchable(_ type: ProviderType) -> Bool {
        switch type {
        case .openai, .anthropic, .gemini, .ollama, .openAICompatible: return true
        case .apple: return false
        }
    }

    /// The cached lists (bare ids) keyed by provider id — the `liveModels` input
    /// for the pure grouping. Age doesn't matter: a stale list beats the
    /// hardcoded fallback.
    public func cachedModels() -> [UUID: [String]] {
        entries.compactMapValues { $0.models.isEmpty ? nil : $0.models }
    }

    /// The picker groups for `providers`: a provider with a cached fetched list
    /// uses it; every other provider falls back to the hardcoded catalog.
    public func groups(for providers: [ProviderConfig]) -> [ModelCatalog.ModelGroup] {
        ModelCatalog.groups(forProviders: providers, liveModels: cachedModels())
    }

    /// Drops cached lists/status for providers no longer in the list (deleted).
    public func prune(keeping providers: [ProviderConfig]) {
        let ids = Set(providers.map(\.id))
        let stale = entries.keys.filter { !ids.contains($0) }
        status = status.filter { ids.contains($0.key) }
        guard !stale.isEmpty else { return }
        for id in stale { entries[id] = nil }
        onEntriesChanged(entries)
    }

    /// Fire-and-forget refresh of every eligible enabled provider. Fetches run in
    /// the background; results republish as they land. A provider fetched within
    /// `ttl` is skipped unless `force`.
    public func refresh(providers: [ProviderConfig], force: Bool = false) {
        for provider in providers where provider.enabled && Self.isFetchable(provider.type) {
            refresh(provider, force: force)
        }
    }

    /// Fire-and-forget single-provider refresh (Refresh button / enable / key save).
    public func refresh(_ provider: ProviderConfig, force: Bool = true) {
        guard Self.isFetchable(provider.type) else { return }
        Task { [weak self] in await self?.fetchNow(provider, force: force) }
    }

    /// Awaitable single-provider fetch + store — the core `refresh` builds on, and
    /// what tests drive directly. Returns whether a fresh list was stored. No-op
    /// (false) when the provider isn't fetchable, is already in flight, or was
    /// fetched within `ttl` and `force` is off. A failure records a status and
    /// keeps any previously cached list.
    @discardableResult
    public func fetchNow(_ provider: ProviderConfig, force: Bool = false) async -> Bool {
        guard Self.isFetchable(provider.type) else { return false }
        let id = provider.id
        if inFlight.contains(id) { return false }
        if !force, let entry = entries[id], now().timeIntervalSince(entry.fetchedAt) < ttl { return false }
        inFlight.insert(id)
        status[id] = .fetching
        let result = await service.fetchModels(for: provider)
        inFlight.remove(id)
        switch result {
        case .success(let models) where !models.isEmpty:
            status[id] = nil
            entries[id] = Entry(models: models, fetchedAt: now())
            onEntriesChanged(entries)
            Log.info("model list fetched: \(provider.type.rawValue) count=\(models.count)")
            return true
        case .success:
            status[id] = .failed(.empty, at: now())
            Log.info("model list fetch failed: \(provider.type.rawValue) reason=empty")
            return false
        case .failure(let error):
            status[id] = .failed(error, at: now())
            Log.info("model list fetch failed: \(provider.type.rawValue) reason=\(error.category)")
            return false
        }
    }

    /// The Providers-tab status line for one provider. Pure.
    public static func statusText(entry: Entry?, status: Status?, now: Date = Date()) -> String {
        switch status {
        case .fetching:
            return "Fetching models…"
        case .failed(let error, _):
            let fallback = entry == nil ? "using the built-in list" : "keeping the last fetched list"
            return "Couldn't fetch models: \(error.message) — \(fallback)."
        case nil:
            if let entry {
                let noun = entry.models.count == 1 ? "model" : "models"
                return "\(entry.models.count) \(noun) fetched \(ClipTime.relative(entry.fetchedAt, now: now))."
            }
            return "Showing the built-in model list."
        }
    }

    public func statusText(for provider: ProviderConfig, now: Date = Date()) -> String {
        Self.statusText(entry: entries[provider.id], status: status[provider.id], now: now)
    }
}
