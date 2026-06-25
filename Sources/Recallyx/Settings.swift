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
    /// Which Return chord the "Paste as keystrokes" action sends for each `\n` in
    /// the typed-out clip. Defaults to ⌥Return — Claude Code's literal-newline
    /// chord — so a plain Return doesn't submit in submit-on-Enter TUIs.
    var pasteKeystrokeNewlineKey: NewlineKey

    /// Transient (never encoded, never compared): set by `init(from:)` when the
    /// `providers` key was ABSENT from the decoded blob and the list was therefore
    /// seeded from current reality. `SettingsStore.init` reads it to persist the
    /// seed exactly once, so the seed's launch-time keychain existence-checks
    /// don't recur on every launch. A present list (incl. an explicit `[]`) or a
    /// fresh `AppSettings()` leaves it `false` — no needless re-persist.
    var providersWereSeededOnDecode: Bool = false

    /// Excludes `providersWereSeededOnDecode` from the persisted blob — it's a
    /// decode-time signal, not stored state.
    private enum CodingKeys: String, CodingKey {
        case retentionCap, captureSensitive, launchAtLogin, usageJournalEnabled
        case fileLogEnabled, defaultModel, actions, ollamaBaseURL, providers
        case searchHistoryShortcut, transformSelectionShortcut
        case pasteKeystrokeNewlineKey
    }

    /// Custom equality that ignores the transient `providersWereSeededOnDecode`
    /// flag (it must not make two otherwise-identical settings compare unequal —
    /// `SettingsStore.didSet` gates `onChange` on `settings != oldValue`).
    static func == (lhs: AppSettings, rhs: AppSettings) -> Bool {
        lhs.retentionCap == rhs.retentionCap
            && lhs.captureSensitive == rhs.captureSensitive
            && lhs.launchAtLogin == rhs.launchAtLogin
            && lhs.usageJournalEnabled == rhs.usageJournalEnabled
            && lhs.fileLogEnabled == rhs.fileLogEnabled
            && lhs.defaultModel == rhs.defaultModel
            && lhs.actions == rhs.actions
            && lhs.ollamaBaseURL == rhs.ollamaBaseURL
            && lhs.providers == rhs.providers
            && lhs.searchHistoryShortcut == rhs.searchHistoryShortcut
            && lhs.transformSelectionShortcut == rhs.transformSelectionShortcut
            && lhs.pasteKeystrokeNewlineKey == rhs.pasteKeystrokeNewlineKey
    }

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
        transformSelectionShortcut: Shortcut = .transformSelectionDefault,
        pasteKeystrokeNewlineKey: NewlineKey = .default
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
        self.pasteKeystrokeNewlineKey = pasteKeystrokeNewlineKey
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
        //
        // Flag the ABSENT case so SettingsStore persists the seed once (Part B):
        // an existing blob from before this feature has no `providers` key, so the
        // seed lives only in memory and its keychain existence-checks would recur
        // every launch until some later save. `contains(.providers)` is true only
        // when the key was actually written — a present-but-malformed value still
        // re-seeds but is NOT flagged (it can't round-trip cleanly, and we avoid
        // overwriting a blob the user may still recover by other means).
        if let decoded = (try? c.decodeIfPresent([ProviderConfig].self, forKey: .providers)) ?? nil {
            providers = decoded
        } else {
            providers = ProviderConfig.seedFromCurrentReality(ollamaBaseURL: ollamaBaseURL)
            providersWereSeededOnDecode = !c.contains(.providers)
        }
        searchHistoryShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .searchHistoryShortcut)) ?? .searchHistoryDefault
        transformSelectionShortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .transformSelectionShortcut)) ?? .transformSelectionDefault
        // Absent (older blobs) or malformed → the ⌥Return default.
        pasteKeystrokeNewlineKey = (try? c.decodeIfPresent(NewlineKey.self, forKey: .pasteKeystrokeNewlineKey)) ?? .default
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
        } else if settings.providersWereSeededOnDecode {
            // Part B — one-shot migration: an existing blob lacked the `providers`
            // key and the decoder just seeded it. Persist immediately so the seed
            // is written exactly once; otherwise the seed's launch-time keychain
            // existence-checks (`seedFromCurrentReality`) would recur every launch.
            // The already-persisted blob now carries an explicit list, so the next
            // launch decodes it unchanged and this branch won't fire again.
            Log.info("settings: seeded providers on first migration — persisting once")
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
