import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "recallyx.tests.\(UUID().uuidString)")!
    }

    @Test func freshStore_hasDefaults() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.settings.retentionCap == 1000)
        #expect(store.settings.captureSensitive == false)
        #expect(store.settings.launchAtLogin == false)
    }

    @Test func changes_persistAndReload() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.settings.retentionCap = 250
        store.settings.captureSensitive = true
        store.flush()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.retentionCap == 250)
        #expect(reloaded.settings.captureSensitive == true)
    }

    @Test func onChange_firesWithNewSettings() {
        let store = SettingsStore(defaults: makeDefaults())
        var seen: Int?
        store.onChange = { seen = $0.retentionCap }
        store.settings.retentionCap = 42
        #expect(seen == 42)
    }

    @Test func missingKeys_decodeToDefaults() throws {
        // A blob saved by an older build with only retentionCap must still load.
        let defaults = makeDefaults()
        let partial = try JSONSerialization.data(withJSONObject: ["retentionCap": 500])
        defaults.set(partial, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.retentionCap == 500)
        #expect(store.settings.captureSensitive == false)
        #expect(store.settings.searchHistoryShortcut == .searchHistoryDefault)
        #expect(store.settings.transformSelectionShortcut == .transformSelectionDefault)
        // The additive Ollama URL key is absent in old blobs → defaults.
        #expect(store.settings.ollamaBaseURL == AppSettings.defaultOllamaBaseURL)
    }

    @Test func deletingActions_staysDeletedAfterReload() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let originalCount = store.settings.actions.count
        #expect(originalCount > 1)

        // Delete one action (mirrors SettingsActionsView.deleteSelected).
        let removedID = store.settings.actions[0].id
        store.settings.actions.removeAll { $0.id == removedID }
        store.flush()
        #expect(store.settings.actions.count == originalCount - 1)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.actions.count == originalCount - 1)
        #expect(!reloaded.settings.actions.contains { $0.id == removedID })
    }

    @Test func debouncedSave_doesNotPersistBeforeKill() async {
        // Documents the durability gap that lost deletes. A bare @Published
        // mutation only schedules a 200ms debounced write; the only flush()
        // callers were app-termination paths. A menu-bar (LSUIElement) app does
        // NOT reliably get applicationWillTerminate on `killall`, and install.sh
        // `killall`s on every reinstall — so a delete made within the debounce
        // window before a kill never reached disk. Here we mutate, do NOT flush,
        // and immediately reload (simulating the kill): the change is absent.
        // The fix is to flush structural edits immediately at the call site
        // (SettingsActionsView) — see deletingAction_immediatePersist below.
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let removedID = store.settings.actions[0].id

        store.settings.actions.removeAll { $0.id == removedID }
        // No flush — abrupt kill before the 200ms debounce fires.
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.actions.contains { $0.id == removedID },
                "without an immediate flush the debounced delete is lost on kill")
    }

    @Test func deletingAction_immediatePersist_survivesKill() {
        // The fix: structural edits flush immediately, so the delete survives an
        // abrupt kill (no debounce wait, no termination callback). Mirrors
        // SettingsActionsView.deleteSelected, which now calls flush() after the
        // mutation.
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let originalCount = store.settings.actions.count
        #expect(originalCount > 1)

        let removedID = store.settings.actions[0].id
        store.settings.actions.removeAll { $0.id == removedID }
        store.flush()  // immediate persist, as deleteSelected now does

        // Simulate an abrupt kill: no sleep, no second flush.
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.actions.count == originalCount - 1)
        #expect(!reloaded.settings.actions.contains { $0.id == removedID })
    }

    @Test func deletingAllActions_staysEmptyAfterReload() {
        // The user deleted every action on purpose — reload must NOT resurrect
        // Action.defaults(). An explicit empty array is a real choice, distinct
        // from a first run where the key is absent.
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.actions.isEmpty == false)

        store.settings.actions.removeAll()
        store.flush()
        #expect(store.settings.actions.isEmpty)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.actions.isEmpty)
    }

    @Test func malformedFieldDoesNotResurrectDeletedActions() throws {
        // A user who has deleted actions saves an empty array, but some OTHER
        // field in the blob is malformed (e.g. written by a different build).
        // Decoding the whole AppSettings throws → load() returns nil → the store
        // falls back to AppSettings(), whose actions = Action.defaults().
        // That silently resurrects every action the user deleted.
        let defaults = makeDefaults()
        // Valid actions:[] but a Shortcut object missing required fields.
        let blob: [String: Any] = [
            "retentionCap": 1000,
            "actions": [],
            "searchHistoryShortcut": ["bogus": 1],
        ]
        let data = try JSONSerialization.data(withJSONObject: blob)
        defaults.set(data, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        // The user deleted their actions; a malformed neighbor field must not
        // bring them back.
        #expect(store.settings.actions.isEmpty)
    }

    @Test func pasteKeystrokeNewlineKey_defaultsToOptionReturn() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.settings.pasteKeystrokeNewlineKey == .optionReturn)
    }

    @Test func pasteKeystrokeNewlineKey_roundTrips() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.settings.pasteKeystrokeNewlineKey = .shiftReturn
        store.flush()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.pasteKeystrokeNewlineKey == .shiftReturn)
    }

    @Test func pasteKeystrokeNewlineKey_absentInBlob_defaultsToOptionReturn() throws {
        // An old blob with no `pasteKeystrokeNewlineKey` key must decode to the
        // ⌥Return default, like the other additive fields.
        let defaults = makeDefaults()
        let partial = try JSONSerialization.data(withJSONObject: ["retentionCap": 500])
        defaults.set(partial, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.pasteKeystrokeNewlineKey == .optionReturn)
    }

    @Test func ollamaBaseURL_defaultsAndRoundTrips() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.ollamaBaseURL == AppSettings.defaultOllamaBaseURL)

        store.settings.ollamaBaseURL = "http://192.168.1.10:11434"
        store.flush()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.ollamaBaseURL == "http://192.168.1.10:11434")
    }

    // MARK: - providers migration / round-trip

    @Test func providers_absentInBlob_seedFromReality() throws {
        // An old blob with no `providers` key must decode to a SEEDED list, not
        // an empty one — so a working setup never loses its providers. We can't
        // assert the exact seeded set (it reads the live keychain/OS), but Ollama
        // is always seeded, so the list is never empty.
        let defaults = makeDefaults()
        let partial = try JSONSerialization.data(withJSONObject: ["retentionCap": 500])
        defaults.set(partial, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(!store.settings.providers.isEmpty)
        #expect(store.settings.providers.contains { $0.type == .ollama })
    }

    @Test func providers_presentInBlob_decodeUnchanged() throws {
        // A blob WITH an explicit providers list decodes exactly as written —
        // the migration seeding must not override a stored list.
        let id = UUID()
        let stored = AppSettings(
            providers: [
                ProviderConfig(id: id, type: .openAICompatible, displayName: "Groq",
                               baseURL: "https://api.groq.com/openai/v1",
                               keychainAccount: "custom-x", models: ["llama-3.1-70b"]),
            ]
        )
        let data = try JSONEncoder().encode(stored)
        let defaults = makeDefaults()
        defaults.set(data, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.providers.count == 1)
        #expect(store.settings.providers.first?.id == id)
        #expect(store.settings.providers.first?.displayName == "Groq")
        #expect(store.settings.providers.first?.models == ["llama-3.1-70b"])
    }

    @Test func providers_explicitEmptyList_isPreserved() throws {
        // The user removed every provider on purpose — an explicit [] must NOT
        // re-seed (distinct from an absent key on an old blob).
        let stored = AppSettings(providers: [])
        let data = try JSONEncoder().encode(stored)
        let defaults = makeDefaults()
        defaults.set(data, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.providers.isEmpty)
    }

    // MARK: - providers migration is one-shot (Part B)

    @Test func providers_absentInBlob_persistsSeedOnce() throws {
        // Part B: an existing (legacy) blob with no `providers` key gets seeded by
        // the decoder; SettingsStore.init must persist that seed immediately so the
        // launch-time keychain existence-checks don't recur every launch.
        let defaults = makeDefaults()
        // Legacy blob: real keys but NO providers key (the pre-feature shape).
        let legacy = try JSONSerialization.data(withJSONObject: [
            "retentionCap": 500,
            "actions": [],
        ])
        defaults.set(legacy, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.providersWereSeededOnDecode)
        #expect(!store.settings.providers.isEmpty)

        // The seed was written back: the persisted blob now carries an explicit
        // `providers` key, so a re-decode is NOT a re-seed (one-shot).
        let persisted = defaults.data(forKey: SettingsStore.storageKey)!
        let json = try JSONSerialization.jsonObject(with: persisted) as! [String: Any]
        #expect(json["providers"] != nil)

        // Reloading the now-migrated blob decodes the stored list unchanged and
        // does NOT flag a re-seed — the checks don't recur.
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.providersWereSeededOnDecode == false)
        #expect(reloaded.settings.providers.map(\.id) == store.settings.providers.map(\.id))
    }

    @Test func providers_explicitEmptyList_notReSeededOrRePersisted() throws {
        // An explicit [] is a deliberate choice — it must not be flagged for a
        // re-seed and the stored blob must be left byte-identical (no needless
        // re-persist).
        let stored = AppSettings(providers: [])
        let data = try JSONEncoder().encode(stored)
        let defaults = makeDefaults()
        defaults.set(data, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.providers.isEmpty)
        #expect(store.settings.providersWereSeededOnDecode == false)
        #expect(defaults.data(forKey: SettingsStore.storageKey) == data)
    }

    @Test func providers_presentList_notReSeededOrRePersisted() throws {
        // A present list decodes unchanged and is not re-persisted by init.
        let stored = AppSettings(providers: [
            ProviderConfig(type: .openai, keychainAccount: KeychainStore.openAIKey.account),
            ProviderConfig(type: .ollama, baseURL: "http://localhost:11434"),
        ])
        let data = try JSONEncoder().encode(stored)
        let defaults = makeDefaults()
        defaults.set(data, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.providers.count == 2)
        #expect(store.settings.providersWereSeededOnDecode == false)
        #expect(defaults.data(forKey: SettingsStore.storageKey) == data)
    }

    @Test func providers_roundTripThroughStore() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let custom = ProviderConfig(type: .openAICompatible, displayName: "Together",
                                    baseURL: "https://api.together.xyz/v1",
                                    keychainAccount: "custom-y", models: ["m1", "m2"])
        store.settings.providers.append(custom)
        store.flush()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.providers.contains { $0.displayName == "Together" && $0.models == ["m1", "m2"] })
    }
}
