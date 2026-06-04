import Foundation
import Testing
@testable import Recallyx

@MainActor
@Suite("HistoryPanelViewModel")
struct HistoryPanelViewModelTests {
    private func textItem(_ s: String) -> HistoryItem {
        HistoryItem(
            id: UUID(), kind: .text, text: s, imageFilename: nil, preview: s, byteSize: s.count,
            sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: Date(), lastUsedAt: Date(), contentHash: ContentHash.of(text: s), imageDimensions: nil
        )
    }

    private func imageItem() -> HistoryItem {
        HistoryItem(
            id: UUID(), kind: .image, text: nil, imageFilename: "x.png", preview: "Image · 10 × 10",
            byteSize: 100, sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: Date(), lastUsedAt: Date(), contentHash: "img", imageDimensions: "10 × 10"
        )
    }

    private func makeVM(_ items: [HistoryItem], onBuiltin: @escaping (BuiltinAction, HistoryItem) -> Void = { _, _ in }) -> HistoryPanelViewModel {
        HistoryPanelViewModel(items: items, onBuiltin: onBuiltin, onDismiss: {})
    }

    @Test func tab_opensActionMenuForTextClip() {
        let vm = makeVM([textItem("hi")])
        vm.tab()
        #expect(vm.mode == .actions)
        #expect(vm.menuItems.map(\.id) == ["builtin.paste", "builtin.copy", "builtin.delete"])
    }

    @Test func tab_imageClip_includesImageActions() {
        let vm = makeVM([imageItem()])
        vm.tab()
        #expect(vm.menuItems.map(\.id) == ["builtin.paste", "builtin.copyFilePath", "builtin.revealInFinder", "builtin.delete"])
    }

    @Test func tab_textClip_appendsSavedActions() {
        let actions = [Action(name: "Upper", icon: "sparkles", steps: [])]
        let vm = HistoryPanelViewModel(items: [textItem("hi")], actions: actions, onBuiltin: { _, _ in }, onDismiss: {})
        vm.tab()
        #expect(vm.menuItems.contains { $0.id.hasPrefix("saved.") })
    }

    @Test func savedAction_runsViaCallback() {
        let action = Action(name: "Upper", icon: "sparkles", steps: [])
        var ran: Action?
        let vm = HistoryPanelViewModel(
            items: [textItem("hi")], actions: [action],
            onBuiltin: { _, _ in }, onRunAction: { a, _ in ran = a }, onDismiss: {}
        )
        vm.tab()
        vm.actionIndex = vm.menuItems.firstIndex { if case .saved = $0 { return true }; return false }!
        vm.confirm()
        #expect(ran?.name == "Upper")
    }

    @Test func escFromActions_returnsToList() {
        let vm = makeVM([textItem("hi")])
        vm.tab()
        #expect(vm.mode == .actions)
        vm.cancel()
        #expect(vm.mode == .list)
    }

    @Test func deleteAction_removesLocallyAndReturnsToList() {
        var deleted: HistoryItem?
        let vm = makeVM([textItem("a"), textItem("b")]) { action, item in
            if action == .delete { deleted = item }
        }
        vm.tab()                       // open actions on "a"
        vm.actionIndex = 2             // Delete
        vm.confirm()
        #expect(deleted?.text == "a")
        #expect(vm.mode == .list)
        #expect(vm.filtered.map(\.text) == ["b"])
    }

    @Test func listEnter_pastesSelected() {
        var pasted: HistoryItem?
        let vm = makeVM([textItem("a"), textItem("b")]) { action, item in
            if action == .paste { pasted = item }
        }
        vm.moveDown()
        vm.confirm()
        #expect(pasted?.text == "b")
    }
}
