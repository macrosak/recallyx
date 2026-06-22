import Foundation
import RecallyxCore

/// Small app preferences persisted as JSON in UserDefaults (history itself lives
/// on disk via `HistoryStore`). Phase 2 extends this with `defaultModel` and the
/// user-defined `actions`; the custom decoder defaults missing keys so older
/// saved blobs keep loading.
struct AppSettings: Codable, Equatable {
    /// Where the local Ollama server lives. `RECALLYX_OLLAMA_URL` overrides it
    /// (escape hatch for unusual setups); otherwise the standard local port.
    /// Re-exports the core default so the app's setting matches the clients'.
    static let defaultOllamaBaseURL: String = recallyxDefaultOllamaBaseURL

    var retentionCap: Int
    var captureSensitive: Bool
    var launchAtLogin: Bool
    /// Opt-in, off-by-default local usage journal (see `UsageJournal`). Never
    /// transmits anything; records non-sensitive events to a file on this Mac.
    var usageJournalEnabled: Bool
    /// Model used by AI steps that don't override it.
    var defaultModel: String
    /// User-defined script/AI action pipelines shown in the Tab menu.
    var actions: [Action]
    /// Base URL of the local Ollama server used by `ollama:*` models.
    var ollamaBaseURL: String
    /// ⌘⇧V by default — opens the history panel.
    var searchHistoryShortcut: Shortcut
    /// ⌃⇧V by default — grabs the selection and opens its actions.
    var transformSelectionShortcut: Shortcut

    init(
        retentionCap: Int = 1000,
        captureSensitive: Bool = false,
        launchAtLogin: Bool = false,
        usageJournalEnabled: Bool = false,
        defaultModel: String = ModelCatalog.default,
        actions: [Action] = Action.defaults(),
        ollamaBaseURL: String = AppSettings.defaultOllamaBaseURL,
        searchHistoryShortcut: Shortcut = .searchHistoryDefault,
        transformSelectionShortcut: Shortcut = .transformSelectionDefault
    ) {
        self.retentionCap = retentionCap
        self.captureSensitive = captureSensitive
        self.launchAtLogin = launchAtLogin
        self.usageJournalEnabled = usageJournalEnabled
        self.defaultModel = defaultModel
        self.actions = actions
        self.ollamaBaseURL = ollamaBaseURL
        self.searchHistoryShortcut = searchHistoryShortcut
        self.transformSelectionShortcut = transformSelectionShortcut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionCap = try c.decodeIfPresent(Int.self, forKey: .retentionCap) ?? 1000
        captureSensitive = try c.decodeIfPresent(Bool.self, forKey: .captureSensitive) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        usageJournalEnabled = try c.decodeIfPresent(Bool.self, forKey: .usageJournalEnabled) ?? false
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ModelCatalog.default
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? Action.defaults()
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? AppSettings.defaultOllamaBaseURL
        searchHistoryShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .searchHistoryShortcut) ?? .searchHistoryDefault
        transformSelectionShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .transformSelectionShortcut) ?? .transformSelectionDefault
    }
}

/// Persists `AppSettings` as JSON in UserDefaults under a versioned key, with a
/// debounced write. Mirrors AI Replace's `SettingsStore`.
@MainActor
final class SettingsStore: ObservableObject {
    static let storageKey = "settings.v1"

    @Published var settings: AppSettings {
        didSet {
            scheduleSave()
            if settings != oldValue { onChange?(settings) }
        }
    }

    /// Fired (post-debounce-schedule) whenever settings change, so the app can
    /// push the new retention cap / sensitive flag into the live stores.
    var onChange: ((AppSettings) -> Void)?

    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults) ?? AppSettings()
        if defaults.data(forKey: Self.storageKey) == nil {
            Self.persist(settings, to: defaults)
        }
    }

    private static func load(from defaults: UserDefaults) -> AppSettings? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.error("SettingsStore decode failed: \(error.localizedDescription) — reseeding")
            return nil
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let pending = settings
        let defaults = self.defaults
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            Self.persist(pending, to: defaults)
        }
    }

    private static func persist(_ settings: AppSettings, to defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: storageKey)
        } catch {
            Log.error("SettingsStore encode failed: \(error.localizedDescription)")
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Self.persist(settings, to: defaults)
    }
}
