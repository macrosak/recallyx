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
        #expect(vm.menuItems.map(\.id) == ["builtin.paste", "builtin.openInPreview", "builtin.copyFilePath", "builtin.revealInFinder", "builtin.delete"])
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

    @Test func tab_clearsQueryAndSwitchesSearchDomain() {
        let vm = makeVM([textItem("alpha"), textItem("beta")])
        vm.query = "alp"
        #expect(vm.searchPlaceholder == "Search clipboard…")
        vm.selectedIndex = 0
        vm.tab()
        #expect(vm.query == "")
        #expect(vm.searchPlaceholder == "Search actions…")
        #expect(vm.countText.hasSuffix("actions"))
    }

    @Test func actionSearch_filtersTheMenu() {
        let actions = [
            Action(name: "Fix grammar", icon: "sparkles", steps: []),
            Action(name: "Pretty-print JSON", icon: "scroll", steps: []),
        ]
        let vm = HistoryPanelViewModel(items: [textItem("x")], actions: actions, onBuiltin: { _, _ in }, onDismiss: {})
        vm.tab()
        let full = vm.filteredMenuItems.count
        vm.query = "json"
        #expect(vm.filteredMenuItems.count < full)
        #expect(vm.filteredMenuItems.contains { $0.searchText == "Pretty-print JSON" })
        #expect(!vm.filteredMenuItems.contains { $0.searchText == "Paste" })
    }

    @Test func escFromActions_restoresClipSearch() {
        let vm = makeVM([textItem("alpha"), textItem("beta")])
        vm.query = "alp"
        vm.selectedIndex = 0
        vm.tab()
        #expect(vm.query == "")
        vm.cancel()
        #expect(vm.mode == .list)
        #expect(vm.query == "alp")
        #expect(vm.searchPlaceholder == "Search clipboard…")
    }

    // MARK: - Async deep-search

    private func longItem(_ tail: String, preview: String = "no match here") -> HistoryItem {
        let padding = String(repeating: "x", count: FuzzyMatcher.searchPrefixLimit)
        let full = padding + tail
        return HistoryItem(
            id: UUID(), kind: .text, text: full, imageFilename: nil, preview: preview,
            byteSize: full.count, sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: Date(), lastUsedAt: Date(), contentHash: tail, imageDimensions: nil
        )
    }

    @Test func deepSearch_mergesLongClipAtRecencyPosition() async {
        // "short" is a regular clip; "longdeep" only matches beyond the prefix.
        // After the async pass, the long clip should appear in the filtered list.
        let short = textItem("hello short")
        let long = longItem("uniquedeeptail")
        // Both items; long is second (lower recency index = older in allItems order).
        let vm = makeVM([short, long])
        vm.query = "uniquedeeptail"
        // Sync pass: short doesn't match; long doesn't sync-match either — filtered empty.
        #expect(vm.filtered.isEmpty || vm.filtered.allSatisfy { $0.id != long.id })
        // Await the deep pass.
        await vm.searchTask?.value
        #expect(vm.filtered.contains { $0.id == long.id })
    }

    @Test func deepSearch_cursorStaysOnSameItemAfterMerge() async {
        // Short clip that sync-matches; long clip that deep-matches.
        // Cursor is on the short clip; after deep merge it should stay on it.
        let short = textItem("findme")
        let long = longItem("findme")  // deep match for same query
        let vm = makeVM([short, long])
        vm.query = "findme"
        // short syncs first → selectedIndex 0
        #expect(vm.selectedItem?.id == short.id)
        let capturedID = vm.selectedItem?.id
        await vm.searchTask?.value
        // Cursor should still point to the same item.
        #expect(vm.selectedItem?.id == capturedID)
    }

    @Test func deepSearch_staleQueryDiscarded() async {
        // Type a query, then change it before the deep pass finishes. The stale
        // result must not overwrite the newer filtered list.
        let long = longItem("stale_tail")
        let vm = makeVM([long])
        vm.query = "stale_tail"
        let staleTask = vm.searchTask
        // Change the query before the task completes.
        vm.query = ""
        // Await the now-cancelled task; filtered should be empty (query cleared).
        await staleTask?.value
        // An empty query returns all items — verify we didn't pollute filtered
        // with a partial deep-search result.
        #expect(vm.filtered.count == 1)   // empty query → all items
    }

    @Test func deepSearch_substringOnly_doesNotMatchSubsequence() async {
        // The deep pass uses lowercased `contains`, not the subsequence scorer.
        // A scattered-subsequence match that spans megabytes should NOT appear.
        let padding = String(repeating: "a", count: FuzzyMatcher.searchPrefixLimit)
        // "zz" only matches if both chars appear anywhere in the tail; "za" would
        // match as subsequence ("z" in "zz" then "a" from padding) but is NOT in
        // the tail as a substring. We use a tail with no "zq" substring.
        let tail = "only_b_characters"
        let full = padding + tail
        let item = HistoryItem(
            id: UUID(), kind: .text, text: full, imageFilename: nil, preview: "plain",
            byteSize: full.count, sourceAppBundleID: nil, sourceAppName: nil,
            sourceAppPath: nil, createdAt: Date(), lastUsedAt: Date(),
            contentHash: tail, imageDimensions: nil
        )
        let vm = makeVM([item])
        vm.query = "zq"   // scattered subsequence could match "xxa...zq" but "zq" is not a substring
        await vm.searchTask?.value
        #expect(vm.filtered.isEmpty)
    }
}
