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
    /// On-by-default rotating diagnostic file log (see `FileLog`). Content-free
    /// (lengths/categories/counts, never clip text) and local-only; the persisted
    /// counterpart to the otherwise-ephemeral stderr/os_log output, so a bug is
    /// already captured on disk when the user reports it.
    var fileLogEnabled: Bool
    /// Model used by AI steps that don't override it.
    var defaultModel: String
    /// User-defined script/AI action pipelines shown in the Tab menu.
    var actions: [Action]
    /// Base URL of the local Ollama server used by `ollama:*` models.
    var ollamaBaseURL: String
    /// The user's explicit AI-provider list, surfaced in the Providers Settings
    /// tab. An enabled entry makes that provider's models appear in the pickers
    /// (replacing the old keychain-presence/always-on availability heuristic).
    /// Holds only references — secrets stay in the Keychain.
    var providers: [ProviderConfig]
    /// ⌘⇧V by default — opens the history panel.
    var searchHistoryShortcut: Shortcut
    /// ⌃⇧V by default — grabs the selection and opens its actions.
    var transformSelectionShortcut: Shortcut

    init(
        retentionCap: Int = 1000,
        captureSensitive: Bool = false,
        launchAtLogin: Bool = false,
        usageJournalEnabled: Bool = false,
        fileLogEnabled: Bool = true,
        defaultModel: String = ModelCatalog.default,
        actions: [Action] = Action.defaults(),
        ollamaBaseURL: String = AppSettings.defaultOllamaBaseURL,
        providers: [ProviderConfig]? = nil,
        searchHistoryShortcut: Shortcut = .searchHistoryDefault,
        transformSelectionShortcut: Shortcut = .transformSelectionDefault
    ) {
        self.retentionCap = retentionCap
        self.captureSensitive = captureSensitive
        self.launchAtLogin = launchAtLogin
        self.usageJournalEnabled = usageJournalEnabled
        self.fileLogEnabled = fileLogEnabled
        self.defaultModel = defaultModel
        self.actions = actions
        self.ollamaBaseURL = ollamaBaseURL
        // nil → seed from current reality (keychain keys present + Ollama always +
        // Apple if available). A fresh first run with no keys yields just Ollama;
        // an existing install keeps every configured provider on migration.
        self.providers = providers ?? ProviderConfig.seedFromCurrentReality(ollamaBaseURL: ollamaBaseURL)
        self.searchHistoryShortcut = searchHistoryShortcut
        self.transformSelectionShortcut = transformSelectionShortcut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode each field independently and tolerantly: a missing OR malformed
        // value falls back to that field's default, instead of throwing and
        // failing the whole blob. Without this, one bad neighbor field (e.g. a
        // shortcut written by a different build) made the entire AppSettings
        // decode throw → SettingsStore reseeded AppSettings() → actions reverted
        // to Action.defaults(), silently resurrecting actions the user deleted.
        // `try?` flattens decodeIfPresent's optional, so `(try? …) ?? default`
        // covers both an absent key (nil) and a malformed value (threw → nil).
        retentionCap = (try? c.decodeIfPresent(Int.self, forKey: .retentionCap)) ?? 1000
        captureSensitive = (try? c.decodeIfPresent(Bool.self, forKey: .captureSensitive)) ?? false
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        usageJournalEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .usageJournalEnabled)) ?? false
        // Default ON: absent (older blobs) or malformed → enabled, so existing
        // installs start persisting logs without any user action.
        fileLogEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .fileLogEnabled)) ?? true
        defaultModel = (try? c.decodeIfPresent(String.self, forKey: .defaultModel)) ?? ModelCatalog.default
        // Absent or malformed → seed defaults; a present-but-empty [] (the user
        // deleted them all) decodes to [] and is preserved.
        actions = (try? c.decodeIfPresent([Action].self, forKey: .actions)) ?? Action.defaults()
        ollamaBaseURL = (try? c.decodeIfPresent(String.self, forKey: .ollamaBaseURL)) ?? AppSettings.defaultOllamaBaseURL
        // Absent → seed the provider list from current reality so an existing
        // setup never loses its configured providers (see seedFromCurrentReality).
        // A present list (incl. an explicit []) decodes unchanged. A malformed
        // value also re-seeds rather than blanking AI entirely.
        providers = (try? c.decodeIfPresent([ProviderConfig].self, forKey: .providers))
            ?? ProviderConfig.seedFromCurrentReality(ollamaBaseURL: ollamaBaseURL)
        searchHistoryShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .searchHistoryShortcut)) ?? .searchHistoryDefault
        transformSelectionShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .transformSelectionShortcut)) ?? .transformSelectionDefault
    }
}

/// Persists `AppSettings` as JSON in UserDefaults under a versioned key, with a
/// debounced write. Mirrors AI Replace's `SettingsStore`.
@MainActor
final class SettingsStore: ObservableObject {
    static let storageKey = "settings.v1"

    @Published var settings: AppSettings {
        didSet {
            if settings.actions.count != oldValue.actions.count {
                Log.info("settings.actions count changed → \(settings.actions.count)")
            }
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
            Log.info("settings persisted: \(settings.actions.count) actions")
        } catch {
            Log.error("settings persist FAILED: \(error.localizedDescription)")
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Log.info("settings flush: persisting \(settings.actions.count) actions")
        Self.persist(settings, to: defaults)
    }
}
