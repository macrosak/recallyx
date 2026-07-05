import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@Suite("Action hotkeys")
struct ActionHotkeyTests {
    private func make(
        keyCode: Int = kVK_ANSI_K,
        modifiers: Int = cmdKey | optionKey,
        label: String = "k",
        enabled: Bool = true
    ) -> Shortcut {
        Shortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers), keyLabel: label, enabled: enabled)
    }

    // MARK: - HotkeyIDRegistry (stable id assignment)

    @Test func registry_idIsStablePerToken() {
        var registry = HotkeyIDRegistry()
        let token = UUID().uuidString
        let first = registry.assign(token)
        let second = registry.assign(token)
        #expect(first == second)
        #expect(first == HotkeyIDRegistry.baseID(forToken: token))
    }

    @Test func registry_idsClearOfBuiltinIDs() {
        // Never collides with the two fixed builtin ids (1, 2).
        for _ in 0..<200 {
            let id = HotkeyIDRegistry.baseID(forToken: UUID().uuidString)
            #expect(id >= 100)
        }
    }

    @Test func registry_distinctTokensGetDistinctIDs() {
        var registry = HotkeyIDRegistry()
        var ids = Set<UInt32>()
        var tokens: [String] = []
        for _ in 0..<300 {
            let token = UUID().uuidString
            tokens.append(token)
            ids.insert(registry.assign(token))
        }
        // Uniqueness invariant holds even if two base hashes collided (probe).
        #expect(ids.count == 300)
        // Every token round-trips id → token.
        for token in tokens {
            let id = registry.assign(token)
            #expect(registry.token(forID: id) == token)
        }
    }

    @Test func registry_secondTokenNeverStealsAnOccupiedID() {
        // Whatever a distinct token hashes to, it must not take an id already
        // owned by another token (the linear-probe guarantee).
        var registry = HotkeyIDRegistry()
        let a = UUID().uuidString
        let idA = registry.assign(a)
        let b = UUID().uuidString
        let idB = registry.assign(b)
        #expect(idA != idB)
        #expect(registry.token(forID: idA) == a)
        #expect(registry.token(forID: idB) == b)
    }

    @Test func registry_removeFreesTheID() {
        var registry = HotkeyIDRegistry()
        let token = UUID().uuidString
        let id = registry.assign(token)
        registry.remove(token)
        #expect(registry.token(forID: id) == nil)
        // Re-assigning the same token yields its deterministic base id again.
        #expect(registry.assign(token) == HotkeyIDRegistry.baseID(forToken: token))
    }

    @Test func registry_removeAllClears() {
        var registry = HotkeyIDRegistry()
        let a = registry.assign(UUID().uuidString)
        registry.removeAll()
        #expect(registry.token(forID: a) == nil)
        #expect(registry.tokenByID.isEmpty)
        #expect(registry.idByToken.isEmpty)
    }

    // MARK: - Validation

    private var appShortcuts: [(action: HotkeyAction, shortcut: Shortcut)] {
        [(.showHistory, .searchHistoryDefault), (.transformSelection, .transformSelectionDefault)]
    }

    @Test func validate_cleanComboPasses() {
        let candidate = make() // ⌘⌥K
        #expect(Shortcut.validateActionShortcut(candidate, appShortcuts: appShortcuts, otherActionShortcuts: []) == nil)
    }

    @Test func validate_noModifierFails() {
        let candidate = make(modifiers: shiftKey)
        #expect(Shortcut.validateActionShortcut(candidate, appShortcuts: appShortcuts, otherActionShortcuts: []) == .noModifier)
    }

    @Test func validate_systemReservedFails() {
        let cmdQ = make(keyCode: kVK_ANSI_Q, modifiers: cmdKey, label: "q")
        #expect(Shortcut.validateActionShortcut(cmdQ, appShortcuts: appShortcuts, otherActionShortcuts: []) == .systemReserved)
    }

    @Test func validate_conflictWithSearchHistory() {
        // ⌘⇧V == searchHistory default.
        let candidate = make(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey, label: "v")
        #expect(Shortcut.validateActionShortcut(candidate, appShortcuts: appShortcuts, otherActionShortcuts: [])
                == .conflictApp(.showHistory))
    }

    @Test func validate_conflictWithTransformSelection() {
        // ⌃⇧V == transformSelection default.
        let candidate = make(keyCode: kVK_ANSI_V, modifiers: controlKey | shiftKey, label: "v")
        #expect(Shortcut.validateActionShortcut(candidate, appShortcuts: appShortcuts, otherActionShortcuts: [])
                == .conflictApp(.transformSelection))
    }

    @Test func validate_conflictWithAnotherActionByName() {
        let taken = make(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey, label: "j")
        let candidate = make(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey, label: "j")
        let result = Shortcut.validateActionShortcut(
            candidate, appShortcuts: appShortcuts,
            otherActionShortcuts: [("Add Czech diacritics", taken)]
        )
        #expect(result == .conflictAction("Add Czech diacritics"))
    }

    @Test func validate_conflictIgnoredWhenOtherActionDisabled() {
        var disabled = make(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey, label: "j")
        disabled.enabled = false
        let candidate = make(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey, label: "j")
        #expect(Shortcut.validateActionShortcut(
            candidate, appShortcuts: appShortcuts,
            otherActionShortcuts: [("Disabled one", disabled)]
        ) == nil)
    }

    @Test func validate_conflictIgnoredWhenAppShortcutDisabled() {
        var offSearch = Shortcut.searchHistoryDefault
        offSearch.enabled = false
        let candidate = make(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey, label: "v")
        #expect(Shortcut.validateActionShortcut(
            candidate,
            appShortcuts: [(.showHistory, offSearch), (.transformSelection, .transformSelectionDefault)],
            otherActionShortcuts: []
        ) == nil)
    }

    // MARK: - Settings decode backward-compatibility

    @Test func settings_decodeWithoutActionShortcutsKey() throws {
        // An older blob has no `actionShortcuts` key → decodes to an empty map,
        // not a throw (the whole blob must still load).
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.actionShortcuts.isEmpty)
    }

    @Test func settings_actionShortcutsRoundTrip() throws {
        let token = UUID().uuidString
        var settings = AppSettings()
        settings.actionShortcuts = [token: make()]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.actionShortcuts[token] == make())
        #expect(decoded == settings)
    }

    @Test func settings_malformedActionShortcutsFallsBackToEmpty() throws {
        // A malformed value must not fail the whole blob (tolerant decode).
        let json = Data(#"{"actionShortcuts": "nonsense"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.actionShortcuts.isEmpty)
    }
}
