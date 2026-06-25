import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@MainActor
@Suite("SettingsProvidersView")
struct SettingsProvidersViewTests {
    private func makeList() -> [ProviderConfig] {
        [
            ProviderConfig(type: .openai),
            ProviderConfig(type: .ollama),
            ProviderConfig(type: .apple),
        ]
    }

    @Test func neighborSelection_picksNextDown() {
        var list = makeList()
        let nextID = list[2].id
        list.remove(at: 1)
        // After removing index 1, index 1 now holds the former index-2 item.
        #expect(SettingsProvidersView.neighborSelection(in: list, removedIndex: 1) == nextID)
    }

    @Test func neighborSelection_lastRowFallsBackToNewLast() {
        var list = makeList()
        let prevID = list[1].id
        list.remove(at: 2)
        #expect(SettingsProvidersView.neighborSelection(in: list, removedIndex: 2) == prevID)
    }

    @Test func neighborSelection_emptyListIsNil() {
        #expect(SettingsProvidersView.neighborSelection(in: [], removedIndex: 0) == nil)
    }
}
