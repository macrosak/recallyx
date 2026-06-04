import Foundation

/// Small app preferences persisted as JSON in UserDefaults (history itself lives
/// on disk via `HistoryStore`). Phase 2 extends this with `defaultModel` and the
/// user-defined `actions`; the custom decoder defaults missing keys so older
/// saved blobs keep loading.
struct AppSettings: Codable, Equatable {
    var retentionCap: Int
    var captureSensitive: Bool
    var launchAtLogin: Bool

    init(retentionCap: Int = 1000, captureSensitive: Bool = false, launchAtLogin: Bool = false) {
        self.retentionCap = retentionCap
        self.captureSensitive = captureSensitive
        self.launchAtLogin = launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionCap = try c.decodeIfPresent(Int.self, forKey: .retentionCap) ?? 1000
        captureSensitive = try c.decodeIfPresent(Bool.self, forKey: .captureSensitive) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
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
