import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@MainActor
@Suite("HistoryPanelViewModel")
struct HistoryPanelViewModelTests {
    /// Items default to "now"; tests that build a multi-item list pass `age` to
    /// encode a real recency order (the vm sorts incoming items newest-first,
    /// pinned-first). `age` is seconds in the past — higher = older.
    private func textItem(_ s: String, age: TimeInterval = 0) -> HistoryItem {
        let t = Date().addingTimeInterval(-age)
        return HistoryItem(
            id: UUID(), kind: .text, text: s, imageFilename: nil, preview: s, byteSize: s.count,
            sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: t, lastUsedAt: t, contentHash: ContentHash.of(text: s), imageDimensions: nil
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
        #expect(vm.menuItems.map(\.id) == ["builtin.paste", "builtin.pasteAsLines", "builtin.copy", "builtin.pin", "builtin.delete", "custom"])
    }

    @Test func tab_imageClip_includesImageActions() {
        let vm = makeVM([imageItem()])
        vm.tab()
        // Image built-ins (Pin before Delete), then Custom… — image clips run AI actions too.
        #expect(vm.menuItems.map(\.id) == ["builtin.paste", "builtin.openInPreview", "builtin.copyFilePath", "builtin.revealInFinder", "builtin.pin", "builtin.delete", "custom"])
    }

    @Test func tab_imageClip_appendsCustomAndSavedActions() {
        let actions = [Action(name: "Extract text", icon: "text.viewfinder", steps: [Step(type: .ai, prompt: "ocr")])]
        let vm = HistoryPanelViewModel(items: [imageItem()], actions: actions, onBuiltin: { _, _ in }, onDismiss: {})
        vm.tab()
        #expect(vm.menuItems.contains { $0.id == "custom" })
        #expect(vm.menuItems.contains { $0.id.hasPrefix("saved.") })
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
        let vm = makeVM([textItem("a", age: 0), textItem("b", age: 1)]) { action, item in
            if action == .delete { deleted = item }
        }
        vm.tab()                       // open actions on "a"
        vm.actionIndex = vm.menuItems.firstIndex { $0.id == "builtin.delete" }!
        vm.confirm()
        #expect(deleted?.text == "a")
        #expect(vm.mode == .list)
        #expect(vm.filtered.map(\.text) == ["b"])
    }

    @Test func buildCustomPrompt_respectsTextToken() {
        #expect(HistoryPanelViewModel.buildCustomPrompt("Translate {{TEXT}} to FR") == "Translate {{TEXT}} to FR")
        #expect(HistoryPanelViewModel.buildCustomPrompt("Summarize") == "Summarize\n\nText: {{TEXT}}")
    }

    @Test func buildCustomPrompt_imageUsesInstructionAsIs() {
        // Image clips feed the image to the AI directly — no {{TEXT}} splice.
        #expect(HistoryPanelViewModel.buildCustomPrompt("Extract the text", isImage: true) == "Extract the text")
        #expect(HistoryPanelViewModel.buildCustomPrompt("Describe {{TEXT}}", isImage: true) == "Describe {{TEXT}}")
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
        let vm = makeVM([textItem("a", age: 0), textItem("b", age: 1), textItem("c", age: 2)]) { action, item in
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
        let vm = makeVM([textItem("a", age: 0), textItem("b", age: 1)]) { action, item in
            if action == .paste { pasted = item }
        }
        vm.moveDown()
        vm.confirm()
        #expect(pasted?.text == "b")
    }

    @Test func pasteItem_pastesClipAtIndex() {
        var pasted: HistoryItem?
        let vm = makeVM([textItem("a", age: 0), textItem("b", age: 1), textItem("c", age: 2)]) { action, item in
            if action == .paste { pasted = item }
        }
        // List order: a (newest), b, c. ⌘2 → index 1 → "b".
        vm.pasteItem(at: 1)
        #expect(pasted?.text == "b")
    }

    @Test func pasteItem_outOfRange_isNoOp() {
        var pasted: HistoryItem?
        let vm = makeVM([textItem("a"), textItem("b")]) { action, item in
            if action == .paste { pasted = item }
        }
        vm.pasteItem(at: 5)
        #expect(pasted == nil)
    }

    @Test func pasteItem_nonListMode_isNoOp() {
        var pasted: HistoryItem?
        let vm = makeVM([textItem("a"), textItem("b")]) { action, item in
            if action == .paste { pasted = item }
        }
        vm.tab()                       // enter actions mode
        #expect(vm.mode == .actions)
        vm.pasteItem(at: 0)
        #expect(pasted == nil)
    }

    // MARK: - Paste usage-journal logging (search-quality MRR)

    /// A VM that records the fields of every `paste` usage event it emits.
    private func vmCapturingPaste(_ items: [HistoryItem], into store: PasteLogStore) -> HistoryPanelViewModel {
        HistoryPanelViewModel(items: items, onBuiltin: { _, _ in }, onDismiss: {}) { event, fields in
            if event == "paste" { store.last = fields }
        }
    }

    /// Reference box so the injected `log` closure can write back without capturing `inout`.
    private final class PasteLogStore { var last: [String: Any]? }

    @Test func logPaste_activeQuery_recordsRankQueryLengthResultCount() {
        let store = PasteLogStore()
        // Both clips match "match"; the pasted one sits 2nd in `filtered`.
        let vm = vmCapturingPaste([textItem("match one", age: 0), textItem("match two", age: 1)], into: store)
        vm.query = "match"
        #expect(vm.filtered.count == 2)
        vm.pasteItem(at: 1)             // 2nd filtered row → rank 2

        let fields = store.last
        #expect(fields?["via"] as? String == "quickKey")
        #expect(fields?["clipKind"] as? String == ClipKind.text.rawValue)
        #expect(fields?["rank"] as? Int == 2)
        #expect(fields?["queryLength"] as? Int == 5)
        #expect(fields?["resultCount"] as? Int == 2)
    }

    @Test func logPaste_activeQuery_firstResultIsRank1() {
        let store = PasteLogStore()
        let vm = vmCapturingPaste([textItem("match one", age: 0), textItem("match two", age: 1)], into: store)
        vm.query = "match"
        vm.confirm()                    // pastes selectedItem == filtered[0] → rank 1

        #expect(store.last?["rank"] as? Int == 1)
        #expect(store.last?["resultCount"] as? Int == 2)
        #expect(store.last?["queryLength"] as? Int == 5)
    }

    @Test func logPaste_emptyQuery_logsOnlyViaAndClipKind() {
        let store = PasteLogStore()
        let vm = vmCapturingPaste([textItem("a", age: 0), textItem("b", age: 1)], into: store)
        // No search query active.
        vm.pasteItem(at: 0)

        let fields = store.last
        #expect(fields?["via"] as? String == "quickKey")
        #expect(fields?["clipKind"] as? String == ClipKind.text.rawValue)
        #expect(fields?["rank"] == nil)
        #expect(fields?["queryLength"] == nil)
        #expect(fields?["resultCount"] == nil)
    }

    @Test func logPaste_whitespaceOnlyQuery_logsNoRankFields() {
        let store = PasteLogStore()
        let vm = vmCapturingPaste([textItem("a", age: 0), textItem("b", age: 1)], into: store)
        vm.query = "   "               // whitespace-only → not an active search
        vm.pasteItem(at: 0)

        #expect(store.last?["rank"] == nil)
        #expect(store.last?["queryLength"] == nil)
        #expect(store.last?["resultCount"] == nil)
    }

    @Test func runSavedAction_runsNthSavedAction() {
        let actions = [
            Action(name: "First", icon: "sparkles", steps: []),
            Action(name: "Second", icon: "scroll", steps: []),
        ]
        var ran: Action?
        let vm = HistoryPanelViewModel(items: [textItem("x")], actions: actions,
            onBuiltin: { _, _ in }, onRunAction: { a, _ in ran = a }, onDismiss: {})
        vm.tab()                       // open actions menu
        vm.runSavedAction(at: 0)       // ⌘1 → first saved action
        #expect(ran?.name == "First")
        vm.runSavedAction(at: 1)       // ⌘2 → second saved action
        #expect(ran?.name == "Second")
    }

    @Test func runSavedAction_skipsBuiltinsAndCustom() {
        // With 2 saved actions, index 2 is out of range (built-ins/Custom… aren't
        // counted) → no-op.
        let actions = [
            Action(name: "First", icon: "sparkles", steps: []),
            Action(name: "Second", icon: "scroll", steps: []),
        ]
        var ran: Action?
        let vm = HistoryPanelViewModel(items: [textItem("x")], actions: actions,
            onBuiltin: { _, _ in }, onRunAction: { a, _ in ran = a }, onDismiss: {})
        vm.tab()
        vm.runSavedAction(at: 2)
        #expect(ran == nil)
    }

    @Test func runSavedAction_nonActionsMode_isNoOp() {
        let actions = [Action(name: "First", icon: "sparkles", steps: [])]
        var ran: Action?
        let vm = HistoryPanelViewModel(items: [textItem("x")], actions: actions,
            onBuiltin: { _, _ in }, onRunAction: { a, _ in ran = a }, onDismiss: {})
        // Still in .list mode (no tab) → no-op.
        #expect(vm.mode == .list)
        vm.runSavedAction(at: 0)
        #expect(ran == nil)
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

    @Test func escFromActions_restoresCursorToSameClip_emptyQuery() {
        // Regression: ⇥ into actions on the 3rd clip then Esc must land back on
        // that clip, not snap the cursor to the top.
        let vm = makeVM([textItem("a", age: 0), textItem("b", age: 1), textItem("c", age: 2)])
        // List order: a (newest), b, c.
        vm.moveDown(); vm.moveDown()       // cursor on "c"
        #expect(vm.selectedItem?.text == "c")
        let targetID = vm.selectedItem?.id
        vm.tab()                           // open actions on "c"
        vm.cancel()                        // Esc back to list
        #expect(vm.mode == .list)
        #expect(vm.selectedIndex != 0)
        #expect(vm.selectedItem?.id == targetID)
        #expect(vm.selectedItem?.text == "c")
    }

    @Test func escFromActions_restoresCursorToSameClip_nonEmptyQuery() {
        let vm = makeVM([textItem("alpha", age: 0), textItem("alpine", age: 1), textItem("beta", age: 2)])
        vm.query = "alp"                   // filters to alpha, alpine
        vm.moveDown()                      // cursor on the 2nd match ("alpine")
        let targetID = vm.selectedItem?.id
        #expect(vm.selectedItem?.text == "alpine")
        vm.tab()                           // open actions
        #expect(vm.query == "")
        vm.cancel()                        // Esc → restores query "alp" and cursor
        #expect(vm.mode == .list)
        #expect(vm.query == "alp")
        #expect(vm.selectedItem?.id == targetID)
        #expect(vm.selectedItem?.text == "alpine")
    }

    @Test func escFromActions_stashedClipGone_fallsBackToTop() {
        // If the clip we entered actions on is removed while in the menu, Esc
        // can't restore it → fall back to index 0.
        var deleted: HistoryItem?
        let vm = makeVM([textItem("a", age: 0), textItem("b", age: 1), textItem("c", age: 2)]) { action, item in
            if action == .delete { deleted = item }
        }
        vm.moveDown(); vm.moveDown()       // cursor on "c"
        #expect(vm.selectedItem?.text == "c")
        vm.tab()                           // open actions on "c"
        // Delete "c" (removes locally + returnToList). Its stashed id is gone.
        vm.actionIndex = vm.menuItems.firstIndex { $0.id == "builtin.delete" }!
        vm.confirm()
        #expect(deleted?.text == "c")
        #expect(vm.mode == .list)
        #expect(vm.selectedIndex == 0)
        #expect(vm.selectedItem?.text == "a")
    }

    // MARK: - Pinning

    private func pinnedTextItem(_ s: String) -> HistoryItem {
        var item = textItem(s)
        item.pinned = true
        return item
    }

    @Test func ordered_putsPinnedFirstThenRecency() {
        let older = textItem("older")
        // Make "newer" genuinely more recent.
        var newer = textItem("newer")
        newer.lastUsedAt = older.lastUsedAt.addingTimeInterval(60)
        var pinnedOld = textItem("pinned-old")
        pinnedOld.pinned = true
        pinnedOld.lastUsedAt = older.lastUsedAt.addingTimeInterval(-60)

        let result = HistoryPanelViewModel.ordered([older, newer, pinnedOld])
        // Pinned first (despite being oldest), then newest unpinned.
        #expect(result.map(\.text) == ["pinned-old", "newer", "older"])
    }

    @Test func buildMenu_unpinForPinnedClip_textKind() {
        let vm = makeVM([pinnedTextItem("hi")])
        vm.tab()
        #expect(vm.menuItems.contains { $0.id == "builtin.unpin" })
        #expect(!vm.menuItems.contains { $0.id == "builtin.pin" })
    }

    @Test func buildMenu_pinForUnpinnedClip_imageKind() {
        let vm = makeVM([imageItem()])
        vm.tab()
        #expect(vm.menuItems.contains { $0.id == "builtin.pin" })
        #expect(!vm.menuItems.contains { $0.id == "builtin.unpin" })
    }

    @Test func emptyQueryFiltered_isPinnedFirst() {
        // "a" is older+unpinned, "b" is newest+unpinned, "p" is pinned (oldest).
        var older = textItem("a")
        var newest = textItem("b")
        var pinned = pinnedTextItem("p")
        let base = Date()
        older.lastUsedAt = base
        newest.lastUsedAt = base.addingTimeInterval(60)
        pinned.lastUsedAt = base.addingTimeInterval(-60)
        let vm = makeVM([older, newest, pinned])
        #expect(vm.filtered.map(\.text) == ["p", "b", "a"])
    }

    @Test func pinAction_togglesAndReordersAllItems() {
        var pinnedFlag: Bool?
        // "a" oldest, "b" newest, cursor on "a".
        var a = textItem("a")
        var b = textItem("b")
        a.lastUsedAt = Date()
        b.lastUsedAt = a.lastUsedAt.addingTimeInterval(60)
        let vm = makeVM([a, b]) { action, item in
            if action == .pin { pinnedFlag = true }
            if action == .unpin { pinnedFlag = false }
        }
        // List order: b (newest), a.
        #expect(vm.filtered.map(\.text) == ["b", "a"])
        vm.moveDown()                  // cursor on "a"
        vm.tab()                       // actions on "a"
        vm.actionIndex = vm.menuItems.firstIndex { $0.id == "builtin.pin" }!
        vm.confirm()
        #expect(pinnedFlag == true)
        #expect(vm.mode == .list)
        // "a" now pinned → sorts to the top.
        #expect(vm.filtered.first?.text == "a")
        #expect(vm.filtered.first?.isPinned == true)
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

    // MARK: - ⌘1–9 quick-key numbers

    private func savedItem(_ name: String) -> ActionMenuItem {
        .saved(Action(name: name, icon: "sparkles", steps: []))
    }

    @Test func listQuickKey_first9RowsNumbered_restNil() {
        // 12 items → rows 0–8 map to ⌘1–⌘9, rows 9–11 map to nil.
        let keys = (0..<12).map { HistoryPanelViewModel.listQuickKey(forRowAt: $0) }
        #expect(keys == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil, nil, nil])
    }

    @Test func actionQuickKey_onlySavedRowsNumbered() {
        // [built-in, built-in, divider-isn't-a-row → saved, saved, saved]:
        // a realistic menu is built-ins → Custom… → saved actions. Only saved
        // rows get 1, 2, 3; built-ins/Custom… get nil.
        let menu: [ActionMenuItem] = [
            .builtin(.paste), .builtin(.copy), .custom,
            savedItem("A"), savedItem("B"), savedItem("C"),
        ]
        let keys = menu.indices.map { HistoryPanelViewModel.actionQuickKey(forRowAt: $0, in: menu) }
        #expect(keys == [nil, nil, nil, 1, 2, 3])
    }

    @Test func actionQuickKey_fewerThan9Saved_noNumberExceedsCount() {
        let menu: [ActionMenuItem] = [.builtin(.paste), savedItem("A"), savedItem("B")]
        let keys = menu.indices.compactMap { HistoryPanelViewModel.actionQuickKey(forRowAt: $0, in: menu) }
        #expect(keys == [1, 2])
        #expect(keys.max() == 2)
    }

    @Test func actionQuickKey_tenthSavedIsNil() {
        // 10 saved actions → the 10th (⌘0 isn't bound) gets nil.
        let menu: [ActionMenuItem] = [.builtin(.paste)] + (1...10).map { savedItem("Saved \($0)") }
        let keys = menu.indices.map { HistoryPanelViewModel.actionQuickKey(forRowAt: $0, in: menu) }
        #expect(keys == [nil, 1, 2, 3, 4, 5, 6, 7, 8, 9, nil])
    }

    // MARK: - openActionsOnTop (⌃⇧V targets the captured clip by id)

    @Test func openActionsOnTop_targetsCapturedClip_notPinnedFirst() {
        // Regression: ⌃⇧V must open the action menu on the just-captured
        // selection, not the first PINNED clip (which sorts first in `filtered`).
        let pinned = pinnedTextItem("pinned")          // sorts first (pinned-first)
        let target = textItem("target")               // the captured selection
        let vm = makeVM([target, pinned])
        #expect(vm.filtered.first?.id == pinned.id)    // precondition: pin leads

        vm.openActionsOnTop(focusId: target.id)
        #expect(vm.mode == .actions)
        #expect(vm.actionItem?.id == target.id)        // NOT the pinned clip
    }

    @Test func openActionsOnTop_nilFocus_targetsFirstFiltered() {
        let pinned = pinnedTextItem("pinned")
        let target = textItem("target")
        let vm = makeVM([target, pinned])

        vm.openActionsOnTop(focusId: nil)
        #expect(vm.mode == .actions)
        #expect(vm.actionItem?.id == pinned.id)        // falls back to filtered[0]
    }

    @Test func openActionsOnTop_unknownFocus_fallsBackToFirstFiltered() {
        let pinned = pinnedTextItem("pinned")
        let target = textItem("target")
        let vm = makeVM([target, pinned])

        vm.openActionsOnTop(focusId: UUID())           // not in the list
        #expect(vm.mode == .actions)
        #expect(vm.actionItem?.id == pinned.id)        // falls back to filtered[0]
    }

    // MARK: - insertCopiedClip (detail-pane ⌘C → new stack clip, keep original selected)

    @Test func insertCopiedClip_insertsAtTop_keepsOriginalSelectedByID() {
        let original = textItem("user: alice\npass: s3cr3t", age: 0)
        let older = textItem("older", age: 10)
        let vm = makeVM([original, older])
        vm.selectedIndex = vm.filtered.firstIndex { $0.id == original.id }!

        let copied = textItem("alice", age: 0)         // newest → sorts to the top
        vm.insertCopiedClip(copied, keepingSelectionOnID: original.id)

        #expect(vm.filtered.first?.id == copied.id)     // new clip is at the top
        #expect(vm.selectedItem?.id == original.id)     // selection stayed on the viewed clip
    }

    @Test func insertCopiedClip_missingKeepID_fallsBackToTop() {
        let original = textItem("orig", age: 0)
        let vm = makeVM([original])

        let copied = textItem("frag", age: 0)
        vm.insertCopiedClip(copied, keepingSelectionOnID: nil)

        #expect(vm.selectedIndex == 0)
        #expect(vm.selectedItem?.id == copied.id)
    }

    @Test func insertCopiedClip_notInListMode_isNoOp() {
        let original = textItem("orig")
        let vm = makeVM([original])
        vm.tab()                                        // → .actions
        let before = vm.filtered.map(\.id)

        let copied = textItem("frag")
        vm.insertCopiedClip(copied, keepingSelectionOnID: original.id)

        #expect(vm.mode == .actions)                    // unchanged
        #expect(vm.filtered.map(\.id) == before)        // list untouched
    }

    @Test func insertCopiedClip_dedupeByID_bumpsNoDuplicate() {
        let original = textItem("user: alice\npass: s3cr3t", age: 0)
        let existing = textItem("alice", age: 20)       // an old clip equal to the copied text
        let vm = makeVM([original, existing])
        vm.selectedIndex = vm.filtered.firstIndex { $0.id == original.id }!

        // The store deduped by content hash: it returns the EXISTING clip's id
        // (bumped to "now"), not a fresh one.
        let bumped = HistoryItem(
            id: existing.id, kind: .text, text: "alice", imageFilename: nil,
            preview: "alice", byteSize: 5,
            sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            createdAt: existing.createdAt, lastUsedAt: Date(),
            contentHash: ContentHash.of(text: "alice"), imageDimensions: nil
        )
        vm.insertCopiedClip(bumped, keepingSelectionOnID: original.id)

        #expect(vm.filtered.filter { $0.id == existing.id }.count == 1)  // no duplicate
        #expect(vm.filtered.first?.id == existing.id)                    // bumped to top
        #expect(vm.selectedItem?.id == original.id)                      // selection preserved
    }

    // MARK: - parseKindFilter (the `:img` / `kind:image` search token)

    @Test func parseKindFilter_imgAlias_loneToken() {
        let r = HistoryPanelViewModel.parseKindFilter(":img")
        #expect(r.kind == .image)
        #expect(r.residual == "")
    }

    @Test func parseKindFilter_kindImage_loneToken() {
        let r = HistoryPanelViewModel.parseKindFilter("kind:image")
        #expect(r.kind == .image)
        #expect(r.residual == "")
    }

    @Test func parseKindFilter_txtAlias_loneToken() {
        let r = HistoryPanelViewModel.parseKindFilter(":txt")
        #expect(r.kind == .text)
        #expect(r.residual == "")
    }

    @Test func parseKindFilter_kindText_loneToken() {
        let r = HistoryPanelViewModel.parseKindFilter("kind:text")
        #expect(r.kind == .text)
        #expect(r.residual == "")
    }

    @Test func parseKindFilter_imgWithResidual_stripsTokenAndOneSpace() {
        let r = HistoryPanelViewModel.parseKindFilter(":img figma")
        #expect(r.kind == .image)
        #expect(r.residual == "figma")
    }

    @Test func parseKindFilter_kindImageWithResidual() {
        let r = HistoryPanelViewModel.parseKindFilter("kind:image figma")
        #expect(r.kind == .image)
        #expect(r.residual == "figma")
    }

    @Test func parseKindFilter_txtWithResidual() {
        let r = HistoryPanelViewModel.parseKindFilter(":txt hello world")
        #expect(r.kind == .text)
        #expect(r.residual == "hello world")    // only the first space is stripped
    }

    @Test func parseKindFilter_caseInsensitiveToken() {
        #expect(HistoryPanelViewModel.parseKindFilter(":IMG").kind == .image)
        #expect(HistoryPanelViewModel.parseKindFilter("KIND:IMAGE foo").kind == .image)
        #expect(HistoryPanelViewModel.parseKindFilter(":IMG Figma").residual == "Figma")  // residual case preserved
    }

    @Test func parseKindFilter_leadingWhitespaceTrimmed() {
        let r = HistoryPanelViewModel.parseKindFilter("   :img logo")
        #expect(r.kind == .image)
        #expect(r.residual == "logo")
    }

    @Test func parseKindFilter_partialToken_passesThrough() {
        for partial in [":", ":i", ":im", "kind", "kind:", "kind:ima"] {
            let r = HistoryPanelViewModel.parseKindFilter(partial)
            #expect(r.kind == nil)
            #expect(r.residual == partial)
        }
    }

    @Test func parseKindFilter_tokenMustEndOrBeFollowedBySpace() {
        // `:imgx` / `kind:images` are NOT tokens — they pass through verbatim.
        #expect(HistoryPanelViewModel.parseKindFilter(":imgx").kind == nil)
        #expect(HistoryPanelViewModel.parseKindFilter(":imgx").residual == ":imgx")
        #expect(HistoryPanelViewModel.parseKindFilter("kind:images").kind == nil)
        #expect(HistoryPanelViewModel.parseKindFilter("kind:images").residual == "kind:images")
    }

    @Test func parseKindFilter_plainQuery_passesThrough() {
        let r = HistoryPanelViewModel.parseKindFilter("invoice")
        #expect(r.kind == nil)
        #expect(r.residual == "invoice")
    }

    @Test func parseKindFilter_emptyQuery_passesThrough() {
        let r = HistoryPanelViewModel.parseKindFilter("")
        #expect(r.kind == nil)
        #expect(r.residual == "")
    }

    // MARK: - kind token applied to the live clip search

    @Test func kindToken_img_filtersToImageClipsOnly() {
        let vm = makeVM([textItem("alpha"), imageItem(), textItem("beta")])
        vm.query = ":img"
        #expect(vm.filtered.allSatisfy { $0.kind == .image })
        #expect(vm.filtered.count == 1)
    }

    @Test func kindToken_kindImage_filtersToImageClipsOnly() {
        let vm = makeVM([textItem("alpha"), imageItem(), textItem("beta")])
        vm.query = "kind:image"
        #expect(vm.filtered.allSatisfy { $0.kind == .image })
        #expect(vm.filtered.count == 1)
    }

    @Test func kindToken_txt_filtersToTextClipsOnly() {
        let vm = makeVM([textItem("alpha"), imageItem(), textItem("beta")])
        vm.query = ":txt"
        #expect(vm.filtered.allSatisfy { $0.kind == .text })
        #expect(vm.filtered.count == 2)
    }

    @Test func kindToken_imgWithResidual_furtherFiltersImages() {
        // Two images with distinguishing preview text; the residual matches one.
        var figma = imageItem()
        figma.preview = "Figma screenshot"
        figma.contentHash = "figma-img"
        figma.id = UUID()
        var other = imageItem()
        other.preview = "Random photo"
        other.contentHash = "other-img"
        other.id = UUID()
        let vm = makeVM([figma, other, textItem("figma notes")])
        vm.query = ":img figma"
        #expect(vm.filtered.allSatisfy { $0.kind == .image })
        #expect(vm.filtered.contains { $0.id == figma.id })
        #expect(!vm.filtered.contains { $0.id == other.id })
        #expect(!vm.filtered.contains { $0.kind == .text })   // the text "figma notes" is excluded
    }

    @Test func plainQuery_unaffectedByKindFilter() {
        let vm = makeVM([textItem("alpha"), imageItem(), textItem("alpine")])
        vm.query = "alp"
        // Normal fuzzy search across all kinds — text clips matching "alp".
        #expect(vm.filtered.allSatisfy { $0.kind == .text })
        #expect(vm.filtered.count == 2)
    }

    @Test func kindToken_loneToken_isRecencyOrderOfThatKind() {
        // A lone token reuses the empty-query (recency) path, kind-filtered.
        let vm = makeVM([textItem("a", age: 0), imageItem(), textItem("b", age: 1)])
        vm.query = ":txt"
        #expect(vm.filtered.map(\.kind) == [.text, .text])
        #expect(vm.filtered.map(\.text) == ["a", "b"])   // recency order preserved
    }

    @Test func kindToken_noOpInActionSearchMode() {
        // In action-search mode `:img` is just menu-filter text — it must not
        // touch the clip list or be treated as a kind filter.
        let actions = [Action(name: "Image describe", icon: "sparkles", steps: [])]
        let vm = HistoryPanelViewModel(items: [textItem("x"), imageItem()], actions: actions,
            onBuiltin: { _, _ in }, onDismiss: {})
        vm.tab()                          // → actions mode, query cleared
        #expect(vm.mode == .actions)
        let clipsBefore = vm.filtered.map(\.id)
        vm.query = ":img"
        // The clip list (`filtered`) is untouched in action mode.
        #expect(vm.filtered.map(\.id) == clipsBefore)
        // And the menu filter ran over the literal token (no kind magic).
        #expect(vm.mode == .actions)
    }
}

/// Pure clamp helper for the floating panel's origin: keeps the whole window
/// inside the screen's visible frame (the multi-display visual is AppKit
/// runtime behavior and not headlessly verifiable; the math is).
@MainActor
@Suite("HistoryPanelController.clampedOrigin")
struct PanelClampTests {
    // 760×562 panel, like the real one, on a 1440×900 visible frame at origin 0.
    private let size = CGSize(width: 760, height: 562)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("Fits as-is — origin unchanged")
    func fitsUnchanged() {
        let proposed = CGPoint(x: 340, y: 300)   // fully inside
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: screen)
        #expect(origin == proposed)
    }

    @Test("Overflow top — pinned down so the top edge stays visible (the bug)")
    func overflowTop() {
        // y+height = 600+562 = 1162 > maxY(900): would clip above the top.
        let proposed = CGPoint(x: 340, y: 600)
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: screen)
        #expect(origin.y == screen.maxY - size.height)   // 900 - 562 = 338
        #expect(origin.x == proposed.x)
        #expect(origin.y + size.height <= screen.maxY)
    }

    @Test("Overflow bottom — pinned up to the visible bottom")
    func overflowBottom() {
        let proposed = CGPoint(x: 340, y: -100)
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: screen)
        #expect(origin.y == screen.minY)
        #expect(origin.y >= screen.minY)
    }

    @Test("Overflow left — pinned to the leading edge")
    func overflowLeft() {
        let proposed = CGPoint(x: -200, y: 300)
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: screen)
        #expect(origin.x == screen.minX)
    }

    @Test("Overflow right — pinned so the trailing edge stays visible")
    func overflowRight() {
        let proposed = CGPoint(x: 1200, y: 300)   // 1200+760 = 1960 > maxX(1440)
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: screen)
        #expect(origin.x == screen.maxX - size.width)   // 1440 - 760 = 680
        #expect(origin.x + size.width <= screen.maxX)
    }

    @Test("Window taller than the screen — keeps the top edge visible")
    func tallerThanScreen() {
        let shortScreen = CGRect(x: 0, y: 0, width: 1440, height: 400)   // 400 < 562
        let proposed = CGPoint(x: 340, y: 100)
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: shortScreen)
        // Top sits at the visible top; the bottom necessarily spills below.
        #expect(origin.y == shortScreen.maxY - size.height)
        #expect(origin.y + size.height == shortScreen.maxY)
    }

    @Test("Window wider than the screen — keeps the leading edge visible")
    func widerThanScreen() {
        let narrowScreen = CGRect(x: 100, y: 0, width: 500, height: 900)   // 500 < 760
        let proposed = CGPoint(x: 50, y: 300)
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: narrowScreen)
        #expect(origin.x == narrowScreen.minX)
    }

    @Test("Non-zero screen origin (external display offset) clamps into that frame")
    func offsetScreen() {
        let offset = CGRect(x: 2000, y: -300, width: 1440, height: 900)
        let proposed = CGPoint(x: 5000, y: 5000)   // far past the top-right
        let origin = HistoryPanelController.clampedOrigin(forSize: size, proposed: proposed, in: offset)
        #expect(origin.x == offset.maxX - size.width)
        #expect(origin.y == offset.maxY - size.height)
    }
}
