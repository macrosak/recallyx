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
        #expect(vm.menuItems.map(\.id) == ["builtin.paste", "builtin.copy", "builtin.delete", "custom"])
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

    @Test func buildCustomPrompt_respectsTextToken() {
        #expect(HistoryPanelViewModel.buildCustomPrompt("Translate {{TEXT}} to FR") == "Translate {{TEXT}} to FR")
        #expect(HistoryPanelViewModel.buildCustomPrompt("Summarize") == "Summarize\n\nText: {{TEXT}}")
    }

    @Test func custom_runsTransientSingleAIStep() {
        var ran: Action?
        let vm = HistoryPanelViewModel(items: [textItem("hello")], actions: [],
            onBuiltin: { _, _ in }, onRunAction: { a, _ in ran = a }, onDismiss: {})
        vm.tab()
        // Custom… is the entry right after the built-ins.
        vm.actionIndex = vm.menuItems.firstIndex { if case .custom = $0 { return true }; return false }!
        vm.confirm()                 // enter custom mode
        #expect(vm.mode == .custom)
        vm.customText = "Make it formal"
        vm.confirm()                 // run
        #expect(ran?.steps.count == 1)
        #expect(ran?.steps.first?.type == .ai)
        #expect(ran?.steps.first?.prompt.contains("Make it formal") == true)
    }

    @Test func editBeforeRun_editsTransientCopyOnly() {
        let saved = Action(name: "Tidy", icon: "sparkles", steps: [
            Step(type: .script, script: "orig-script"),
            Step(type: .ai, prompt: "orig-prompt"),
        ])
        var ran: Action?
        let vm = HistoryPanelViewModel(items: [textItem("x")], actions: [saved],
            onBuiltin: { _, _ in }, onRunAction: { a, _ in ran = a }, onDismiss: {})
        vm.tab()
        vm.actionIndex = vm.menuItems.firstIndex { if case .saved = $0 { return true }; return false }!
        vm.tab()                     // edit-before-run
        #expect(vm.mode == .edit)
        #expect(vm.editBody == "orig-script")
        vm.editBody = "edited-script"
        vm.tab()                     // advance to step 2 (commits step 1)
        #expect(vm.editStepIndex == 1)
        #expect(vm.editBody == "orig-prompt")
        vm.editBody = "edited-prompt"
        vm.runEdit()
        #expect(ran?.steps[0].script == "edited-script")
        #expect(ran?.steps[1].prompt == "edited-prompt")
        // The persisted action is untouched.
        #expect(saved.steps[0].script == "orig-script")
    }

    @Test func actionMenu_targetsCapturedItem_evenIfSelectionResets() {
        // Regression: opening the menu on a non-first item then having the list
        // selection reset (e.g. the search field re-firing its binding) must NOT
        // make the action apply to the first item.
        var pasted: HistoryItem?
        let vm = makeVM([textItem("a"), textItem("b"), textItem("c")]) { action, item in
            if action == .paste { pasted = item }
        }
        vm.moveDown(); vm.moveDown()      // cursor on "c"
        vm.tab()                          // open actions on "c"
        #expect(vm.actionItem?.text == "c")
        vm.selectedIndex = 0              // simulate the list cursor snapping back
        vm.actionIndex = 0               // Paste
        vm.confirm()
        #expect(pasted?.text == "c")      // still acts on "c", not "a"
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
