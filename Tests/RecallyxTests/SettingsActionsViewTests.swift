import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@MainActor
@Suite("SettingsActionsView neighbor selection")
struct SettingsActionsViewTests {
    private func actions(_ n: Int) -> [Action] {
        (0..<n).map { Action(name: "A\($0)", icon: "sparkles", steps: []) }
    }

    @Test func selectsNextDownAfterDeletingMiddle() {
        // Started with [A0, A1, A2, A3], deleted index 1 → list is [A0, A2, A3].
        // The neighbor at index 1 is now A2.
        var list = actions(4)
        list.remove(at: 1)
        let selected = SettingsActionsView.neighborSelection(in: list, removedIndex: 1)
        #expect(selected == list[1].id)  // A2
    }

    @Test func selectsNewLastAfterDeletingLast() {
        // Started with [A0, A1, A2], deleted the last (index 2) → [A0, A1].
        // No row at index 2 anymore, so fall back to the new last row, A1.
        var list = actions(3)
        list.remove(at: 2)
        let selected = SettingsActionsView.neighborSelection(in: list, removedIndex: 2)
        #expect(selected == list[1].id)  // A1, the new last
    }

    @Test func selectsRemainingAfterDeletingFirst() {
        // Deleting the first leaves the (old) second at index 0.
        var list = actions(3)
        let secondID = list[1].id
        list.remove(at: 0)
        let selected = SettingsActionsView.neighborSelection(in: list, removedIndex: 0)
        #expect(selected == secondID)
    }

    @Test func nilWhenListBecomesEmpty() {
        let selected = SettingsActionsView.neighborSelection(in: [], removedIndex: 0)
        #expect(selected == nil)
    }

    // MARK: - Drag reorder (.onMove math)

    @Test func dragRowDownReorders() {
        // [A0, A1, A2, A3]; drag A0 down to sit before index 2 → [A1, A0, A2, A3].
        let list = actions(4)
        let moved = SettingsActionsView.moving(list, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(moved.map(\.name) == ["A1", "A0", "A2", "A3"])
    }

    @Test func dragRowUpReorders() {
        // [A0, A1, A2, A3]; drag A3 up to the front → [A3, A0, A1, A2].
        let list = actions(4)
        let moved = SettingsActionsView.moving(list, fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(moved.map(\.name) == ["A3", "A0", "A1", "A2"])
    }

    @Test func dragToSamePositionIsNoOp() {
        // Dropping right back where it started leaves the order unchanged.
        let list = actions(3)
        let moved = SettingsActionsView.moving(list, fromOffsets: IndexSet(integer: 1), toOffset: 1)
        #expect(moved.map(\.id) == list.map(\.id))
    }
}
