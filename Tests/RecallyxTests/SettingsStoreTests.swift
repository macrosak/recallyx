import Foundation
import Testing
@testable import Recallyx

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
    }
}
