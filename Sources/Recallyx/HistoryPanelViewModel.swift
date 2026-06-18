import Foundation

/// Drives the ⌘⇧V history panel. Two modes for now: the list (search + paste)
/// and the per-clip action menu (Tab). The columns swap by mode, mirroring the
/// proposal's action flow:
///   • list    → list | detail
///   • actions → detail | action menu
@MainActor
final class HistoryPanelViewModel: ObservableObject {
    enum Mode: Equatable {
        case list
        case actions
        /// Typing a one-off Custom… prompt.
        case custom
        /// Editing a transient copy of a saved action, paginated over its steps.
        case edit
    }

    /// The same search field serves two domains: clips in list mode, the action
    /// list once you're in an action state. `didSet` routes the filter to the
    /// active domain. (Guarded against same-value re-writes — SwiftUI re-fires
    /// the binding when the field resigns focus, which would otherwise reset the
    /// cursor out from under an open menu.)
    @Published var query: String = "" {
        didSet { if query != oldValue { onQueryChanged() } }
    }
    @Published private(set) var filtered: [HistoryItem]
    @Published var selectedIndex: Int = 0
    @Published private(set) var mode: Mode = .list
    /// Full menu for the captured clip; `filteredMenuItems` is what's shown/navigated.
    @Published private(set) var menuItems: [ActionMenuItem] = []
    @Published private(set) var filteredMenuItems: [ActionMenuItem] = []
    @Published var actionIndex: Int = 0
    /// The clip the action menu / custom / edit modes operate on. Captured when
    /// the menu opens so it stays fixed even if `selectedIndex` shifts.
    @Published private(set) var actionItem: HistoryItem?

    /// The clip search, stashed while we're in an action state so it can be
    /// restored when we return to the list (Tab clears the field for action
    /// search; Esc brings the clip search back).
    private var savedClipQuery: String = ""

    /// Placeholder + count adapt to the active search domain.
    var searchPlaceholder: String { mode == .list ? "Search clipboard…" : "Search actions…" }
    var countText: String {
        switch mode {
        case .list: return "\(filtered.count) clips"
        case .actions: return "\(filteredMenuItems.count) actions"
        case .custom, .edit: return "\(menuItems.count) actions"
        }
    }

    // Ad-hoc AI state.
    @Published var customText: String = ""
    @Published private(set) var editAction: Action?
    @Published private(set) var editStepIndex: Int = 0
    @Published var editBody: String = ""

    private(set) var allItems: [HistoryItem]
    private let actions: [Action]
    private let onBuiltin: (BuiltinAction, HistoryItem) -> Void
    private let onRunAction: (Action, HistoryItem) -> Void
    private let onDismiss: () -> Void

    /// In-flight async deep-search task; cancelled on each new keystroke.
    /// Internal (not private) so tests can await it via `searchTask?.value`.
    var searchTask: Task<Void, Never>?

    init(
        items: [HistoryItem],
        actions: [Action] = [],
        onBuiltin: @escaping (BuiltinAction, HistoryItem) -> Void,
        onRunAction: @escaping (Action, HistoryItem) -> Void = { _, _ in },
        onDismiss: @escaping () -> Void
    ) {
        let ordered = Self.ordered(items)
        self.allItems = ordered
        self.filtered = ordered
        self.actions = actions
        self.onBuiltin = onBuiltin
        self.onRunAction = onRunAction
        self.onDismiss = onDismiss
    }

    /// Display order: pinned clips first, then by recency (newest first). Applied
    /// where items enter the vm; the store keeps pure recency order internally.
    static func ordered(_ items: [HistoryItem]) -> [HistoryItem] {
        // Stable: enumerated index breaks ties so equal-recency items keep their
        // incoming (store recency) order rather than being shuffled by an
        // unstable sort.
        items.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }  // pinned first
            if a.element.recency != b.element.recency { return a.element.recency > b.element.recency }  // then newest
            return a.offset < b.offset
        }.map(\.element)
    }

    var selectedItem: HistoryItem? {
        guard filtered.indices.contains(selectedIndex) else { return nil }
        return filtered[selectedIndex]
    }

    /// The clip the detail pane / action menu should show: the cursor item in
    /// the list, or the captured target once we're acting on one.
    var detailItem: HistoryItem? {
        mode == .list ? selectedItem : actionItem
    }

    var isEmpty: Bool { allItems.isEmpty }

    // MARK: - Navigation

    func moveUp() {
        switch mode {
        case .list: stepList(by: -1)
        case .actions: stepAction(by: -1)
        case .custom, .edit: break
        }
    }

    func moveDown() {
        switch mode {
        case .list: stepList(by: 1)
        case .actions: stepAction(by: 1)
        case .custom, .edit: break
        }
    }

    /// ↵ — list: paste the selected clip; actions: run/open the highlighted
    /// entry; custom: run the one-off prompt.
    func confirm() {
        switch mode {
        case .list:
            guard let item = selectedItem else { return }
            onBuiltin(.paste, item)
        case .actions:
            runSelectedAction()
        case .custom:
            runCustom()
        case .edit:
            break // ⌘↵ runs (see runEdit); plain ↵ adds a newline in the editor
        }
    }

    /// esc — actions/custom/edit: step back; list: close the panel.
    func cancel() {
        switch mode {
        case .actions: returnToList()
        case .custom, .edit: backToActions()
        case .list: onDismiss()
        }
    }

    /// ⇥ — list: open the action menu; actions: edit-before-run the highlighted
    /// saved action; edit: advance to the next step.
    func tab() {
        switch mode {
        case .list:
            guard let item = selectedItem else { return }
            actionItem = item
            menuItems = buildMenu(for: item)
            // Hand the search field to the action list: stash the clip query,
            // clear it, then filter the menu (empty query → all).
            savedClipQuery = query
            mode = .actions
            query = ""
            applyMenuFilter()
            actionIndex = 0
        case .actions:
            if case .saved(let action) = currentEntry, !action.steps.isEmpty {
                enterEdit(action)
            }
        case .edit:
            advanceEditStep()
        case .custom:
            break
        }
    }

    /// Built-ins for the clip kind, then (text only) Custom… + the saved actions.
    /// The Pin/Unpin entry is per-item (not per-kind), so it's inserted here
    /// rather than in `BuiltinAction.entries(for:)`: right before Delete.
    private func buildMenu(for item: HistoryItem) -> [ActionMenuItem] {
        var entries: [ActionMenuItem] = BuiltinAction.entries(for: item.kind).map { .builtin($0) }
        let pin: ActionMenuItem = .builtin(item.isPinned ? .unpin : .pin)
        if let deleteIdx = entries.firstIndex(where: { $0.id == "builtin.delete" }) {
            entries.insert(pin, at: deleteIdx)
        } else {
            entries.append(pin)
        }
        if item.kind == .text {
            entries.append(.custom)
            entries += actions.map { .saved($0) }
        }
        return entries
    }

    private var currentEntry: ActionMenuItem? {
        filteredMenuItems.indices.contains(actionIndex) ? filteredMenuItems[actionIndex] : nil
    }

    // MARK: - Running

    private func runSelectedAction() {
        guard let item = actionItem, let entry = currentEntry else { return }
        switch entry {
        case .builtin(.delete):
            onBuiltin(.delete, item)
            allItems.removeAll { $0.id == item.id }
            returnToList()
        case .builtin(.pin), .builtin(.unpin):
            // Act locally + stay open (like Delete), then re-sort so the pin
            // jumps to the top of the list.
            let nowPinned = (entry.id == "builtin.pin")
            onBuiltin(nowPinned ? .pin : .unpin, item)
            if let i = allItems.firstIndex(where: { $0.id == item.id }) {
                allItems[i].pinned = nowPinned
            }
            allItems = Self.ordered(allItems)
            returnToList()
        case .builtin(let action):
            // Controller performs the action and dismisses the panel.
            onBuiltin(action, item)
        case .saved(let action):
            onRunAction(action, item)
        case .custom:
            enterCustom()
        }
    }

    // MARK: - Ad-hoc AI

    /// Build the prompt for a one-off Custom… run: honor `{{TEXT}}` if present,
    /// else append the clip after the instruction. (Ported from AI Replace.)
    static func buildCustomPrompt(_ userInput: String) -> String {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("{{TEXT}}") { return trimmed }
        return "\(trimmed)\n\nText: {{TEXT}}"
    }

    private func enterCustom() {
        customText = ""
        mode = .custom
    }

    /// Run the typed instruction once as a transient single-AI-step action.
    private func runCustom() {
        guard let item = actionItem else { return }
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let transient = Action(name: "Custom", icon: "sparkle", steps: [
            Step(type: .ai, prompt: Self.buildCustomPrompt(trimmed)),
        ])
        onRunAction(transient, item)
    }

    private func enterEdit(_ action: Action) {
        editAction = action
        editStepIndex = 0
        editBody = body(of: action.steps[0])
        mode = .edit
    }

    /// Commit the current step's edit and move to the next (wrapping).
    private func advanceEditStep() {
        guard var action = editAction, !action.steps.isEmpty else { return }
        commitEditBody(into: &action)
        editAction = action
        editStepIndex = (editStepIndex + 1) % action.steps.count
        editBody = body(of: action.steps[editStepIndex])
    }

    /// ⌘↵ — commit the current edit and run the modified transient action once.
    func runEdit() {
        guard let item = actionItem, var action = editAction else { return }
        commitEditBody(into: &action)
        onRunAction(action, item)
    }

    var editStepCount: Int { editAction?.steps.count ?? 0 }

    private func commitEditBody(into action: inout Action) {
        guard action.steps.indices.contains(editStepIndex) else { return }
        if action.steps[editStepIndex].type == .ai {
            action.steps[editStepIndex].prompt = editBody
        } else {
            action.steps[editStepIndex].script = editBody
        }
    }

    private func body(of step: Step) -> String {
        step.type == .ai ? step.prompt : step.script
    }

    private func backToActions() {
        editAction = nil
        customText = ""
        editBody = ""
        mode = .actions
        // Reset the action search to show the full menu again.
        query = ""
        applyMenuFilter()
        actionIndex = 0
    }

    /// Return from an action state to the list, restoring the stashed clip search.
    private func returnToList() {
        searchTask?.cancel()
        searchTask = nil
        actionItem = nil
        menuItems = []
        filteredMenuItems = []
        mode = .list
        if query != savedClipQuery {
            query = savedClipQuery   // didSet → refreshClips for the restored query
        } else {
            refreshClips()           // same value (or allItems changed) — refresh explicitly
        }
    }

    // MARK: - Filtering

    private func onQueryChanged() {
        switch mode {
        case .list: refreshClips()
        case .actions: applyMenuFilter(); actionIndex = 0
        case .custom, .edit: break   // the field isn't the active control here
        }
    }

    private func refreshClips() {
        searchTask?.cancel()
        searchTask = nil

        let q = query
        // Empty query: show all in pinned-first order (don't run through the
        // fuzzy ranker, which would rank by match quality and interleave pins).
        guard !q.isEmpty else {
            filtered = allItems
            selectedIndex = 0
            return
        }

        // Sync pass: instant result from bounded prefix.
        let syncResult = FuzzyMatcher.rank(allItems, query: q)
        filtered = syncResult
        selectedIndex = 0

        // Async deep pass: scan full text of long clips that didn't sync-match.
        // Task.detached is required — an unqualified Task { } inherits @MainActor
        // and would block the main thread for the entire scan.
        let syncIDs = Set(syncResult.map(\.id))
        let deepCandidates = allItems.filter { item in
            guard !syncIDs.contains(item.id),
                  let text = item.text,
                  text.utf8.count > FuzzyMatcher.searchPrefixLimit else { return false }
            return true
        }
        guard !deepCandidates.isEmpty else { return }

        let allItemsSnapshot = allItems
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var deepMatchIDs = Set<UUID>()
            for item in deepCandidates {
                if Task.isCancelled { return }
                // range(of:options:) avoids allocating a lowercased copy of the
                // full multi-MB string; substring-only (not subsequence) for precision.
                if let text = item.text,
                   text.range(of: q, options: .caseInsensitive) != nil {
                    deepMatchIDs.insert(item.id)
                }
            }
            if Task.isCancelled || deepMatchIDs.isEmpty { return }
            guard let self else { return }
            await self.mergeDeepResults(
                deepMatchIDs: deepMatchIDs, syncIDs: syncIDs,
                snapshot: allItemsSnapshot, capturedQuery: q
            )
        }
    }

    /// Called on the main actor after the off-actor deep scan completes. Validates
    /// that the query hasn't changed since the scan started, then merges results.
    @MainActor
    private func mergeDeepResults(
        deepMatchIDs: Set<UUID>, syncIDs: Set<UUID>,
        snapshot: [HistoryItem], capturedQuery: String
    ) {
        guard capturedQuery == query, !Task.isCancelled else { return }
        let allMatchIDs = syncIDs.union(deepMatchIDs)
        let selectedID = selectedItem?.id
        // Rebuild in recency order; re-find cursor by ID so selection doesn't jump.
        filtered = snapshot.filter { allMatchIDs.contains($0.id) }
        if let id = selectedID, let newIdx = filtered.firstIndex(where: { $0.id == id }) {
            selectedIndex = newIdx
        }
    }

    /// Filter the menu in place (preserving the built-ins → saved order so the
    /// "Saved actions" divider still groups correctly).
    private func applyMenuFilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        filteredMenuItems = q.isEmpty
            ? menuItems
            : menuItems.filter { FuzzyMatcher.score($0.searchText, query: q) != nil }
    }

    private func stepList(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), filtered.count - 1)
    }

    private func stepAction(by delta: Int) {
        guard !filteredMenuItems.isEmpty else { return }
        actionIndex = min(max(actionIndex + delta, 0), filteredMenuItems.count - 1)
    }
}

/// Relative + clock time formatting for the list rows and detail footer.
enum ClipTime {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) hr ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
}
