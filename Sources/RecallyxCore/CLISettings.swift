import Foundation

/// The subset of the app's persisted `AppSettings` blob that the `recallyx` CLI
/// needs — decoded from the same JSON the app writes to UserDefaults (key
/// `settings.v1`, domain `io.github.macrosak.recallyx`). Only RecallyxCore types
/// appear here (`Action` / `ProviderConfig`) so this stays in the shared,
/// iOS-buildable library and is unit-testable; the full `AppSettings` lives in
/// the app target because it also carries `Shortcut` (Carbon/AppKit).
///
/// Decoding is **tolerant** — an absent or malformed field falls back to its
/// default rather than throwing — mirroring `AppSettings.init(from:)`, so a blob
/// written by a newer/older build still yields usable actions.
public struct CLISettings: Equatable {
    public static let storageKey = "settings.v1"

    public var actions: [Action]
    public var defaultModel: String
    public var ollamaBaseURL: String
    public var providers: [ProviderConfig]

    public init(
        actions: [Action] = Action.defaults(),
        defaultModel: String = ModelCatalog.default,
        ollamaBaseURL: String = recallyxDefaultOllamaBaseURL,
        providers: [ProviderConfig] = []
    ) {
        self.actions = actions
        self.defaultModel = defaultModel
        self.ollamaBaseURL = ollamaBaseURL
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case actions, defaultModel, ollamaBaseURL, providers
    }

    /// Decode from the raw settings JSON. Never throws: a bad blob yields the
    /// defaults (the app would have reseeded too).
    public static func decode(from data: Data) -> CLISettings {
        guard let container = try? JSONDecoder().decode(Tolerant.self, from: data) else {
            return CLISettings()
        }
        return container.settings
    }

    /// Resolve a custom-endpoint id → (baseURL, keychainAccount) from the decoded
    /// provider list, for `AIClient`/`ActionRunner`'s `customEndpoint` resolver.
    /// Only *enabled* custom providers resolve (a removed/disabled one → nil, so
    /// the runner throws `customEndpointUnavailable`). Mirrors the app's resolver.
    public func customEndpoint(for providerID: String) -> AIClient.CustomEndpoint? {
        guard let provider = providers.first(where: {
            $0.enabled
                && $0.type == .openAICompatible
                && $0.id.uuidString.lowercased() == providerID.lowercased()
        }), let baseURL = provider.baseURL else { return nil }
        let account = provider.keychainAccount ?? ProviderConfig.customKeychainAccount(for: provider.id)
        return (baseURL: baseURL, keychainAccount: account)
    }

    /// Case-insensitive lookup of a saved action by name.
    public func action(named name: String) -> Action? {
        actions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Private tolerant `Decodable` shim: each field independently falls back.
    private struct Tolerant: Decodable {
        let settings: CLISettings
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let actions = ((try? c.decodeIfPresent([Action].self, forKey: .actions)) ?? nil) ?? Action.defaults()
            let defaultModel = ((try? c.decodeIfPresent(String.self, forKey: .defaultModel)) ?? nil) ?? ModelCatalog.default
            let ollamaBaseURL = ((try? c.decodeIfPresent(String.self, forKey: .ollamaBaseURL)) ?? nil) ?? recallyxDefaultOllamaBaseURL
            let providers = ((try? c.decodeIfPresent([ProviderConfig].self, forKey: .providers)) ?? nil) ?? []
            settings = CLISettings(
                actions: actions,
                defaultModel: defaultModel,
                ollamaBaseURL: ollamaBaseURL,
                providers: providers
            )
        }
    }
}
