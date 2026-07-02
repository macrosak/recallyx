import Foundation

/// Drives the ⌘⇧V history panel. Two modes for now: the list (search + paste)
/// and the per-clip action menu (Tab). The columns swap by mode, mirroring the
/// proposal's action flow:
///   • list    → list | detail
///   • actions → detail | action menu
@MainActor
public final class HistoryPanelViewModel: ObservableObject {
    public enum Mode: Equatable {
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
    @Published public var query: String = "" {
        didSet { if query != oldValue { onQueryChanged() } }
    }
    @Published public private(set) var filtered: [HistoryItem]
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var mode: Mode = .list
    /// Full menu for the captured clip; `filteredMenuItems` is what's shown/navigated.
    @Published public private(set) var menuItems: [ActionMenuItem] = []
    @Published public private(set) var filteredMenuItems: [ActionMenuItem] = []
    @Published public var actionIndex: Int = 0
    /// The clip the action menu / custom / edit modes operate on. Captured when
    /// the menu opens so it stays fixed even if `selectedIndex` shifts.
    @Published public private(set) var actionItem: HistoryItem?

    /// True while the user holds ⌘ over the open panel. Reveals the ⌘1–9
    /// quick-key badges on eligible rows (replacing their trailing timestamp /
    /// accessory). Set/cleared by the controller's `.flagsChanged` monitor and
    /// reset to false on dismiss so a stale held-state never sticks.
    @Published public var commandHeld: Bool = false

    /// The clip search, stashed while we're in an action state so it can be
    /// restored when we return to the list (Tab clears the field for action
    /// search; Esc brings the clip search back).
    private var savedClipQuery: String = ""

    /// The id of the clip the cursor was on when we entered an action state, so
    /// Esc can restore the cursor to that clip instead of snapping to the top.
    private var savedClipID: UUID?

    /// Placeholder + count adapt to the active search domain.
    public var searchPlaceholder: String { mode == .list ? "Search clipboard…" : "Search actions…" }
    public var countText: String {
        switch mode {
        case .list: return "\(filtered.count) clips"
        case .actions: return "\(filteredMenuItems.count) actions"
        case .custom, .edit: return "\(menuItems.count) actions"
        }
    }

    // Ad-hoc AI state.
    @Published public var customText: String = ""
    @Published public private(set) var editAction: Action?
    @Published public private(set) var editStepIndex: Int = 0
    @Published public var editBody: String = ""

    private(set) var allItems: [HistoryItem]
    private let actions: [Action]
    private let onBuiltin: (BuiltinAction, HistoryItem) -> Void
    private let onRunAction: (Action, HistoryItem) -> Void
    private let onDismiss: () -> Void
    /// Emit a usage-journal event (no-op when the journal is disabled). Only
    /// non-sensitive fields — for search the *length*, never the query text.
    private let log: (String, [String: Any]) -> Void

    /// In-flight async deep-search task; cancelled on each new keystroke.
    /// Internal (not private) so tests can await it via `searchTask?.value`.
    public var searchTask: Task<Void, Never>?

    /// Debounce for the `search` usage event — log on a short pause, not on
    /// every keystroke, so a fast typist produces one event per query, not one
    /// per character.
    private var searchLogTask: Task<Void, Never>?

    public init(
        items: [HistoryItem],
        actions: [Action] = [],
        onBuiltin: @escaping (BuiltinAction, HistoryItem) -> Void,
        onRunAction: @escaping (Action, HistoryItem) -> Void = { _, _ in },
        onDismiss: @escaping () -> Void,
        log: @escaping (String, [String: Any]) -> Void = { _, _ in }
    ) {
        let ordered = Self.ordered(items)
        self.allItems = ordered
        self.filtered = ordered
        self.actions = actions
        self.onBuiltin = onBuiltin
        self.onRunAction = onRunAction
        self.onDismiss = onDismiss
        self.log = log
    }

    /// Display order: pinned clips first, then by recency (newest first). Applied
    /// where items enter the vm; the store keeps pure recency order internally.
    public static func ordered(_ items: [HistoryItem]) -> [HistoryItem] {
        // Stable: enumerated index breaks ties so equal-recency items keep their
        // incoming (store recency) order rather than being shuffled by an
        // unstable sort.
        items.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }  // pinned first
            if a.element.recency != b.element.recency { return a.element.recency > b.element.recency }  // then newest
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Parse a leading kind token off a clip-search query. A query that *starts*
    /// with `:img` / `kind:image` filters the list to image clips; `:txt` /
    /// `kind:text` to text clips. The token (and one following space) is stripped;
    /// the rest is the residual query applied as a normal search over that kind.
    ///
    /// Only a *complete* token at the start triggers — partial input (`:`, `:im`)
    /// passes through unchanged as ordinary search text. Case-insensitive. A lone
    /// token (`:img`) yields `(.image, "")` → recency order of that kind. Pure;
    /// the wiring restricts the candidate set before the existing search runs.
    public static func parseKindFilter(_ query: String) -> (kind: ClipKind?, residual: String) {
        // Trim only leading whitespace — trailing/inner spacing belongs to the
        // residual the search then sees.
        let trimmed = String(query.drop { $0 == " " || $0 == "\t" })
        let lower = trimmed.lowercased()

        // Longest aliases first so `kind:image` isn't shadowed by a shorter token.
        let tokens: [(token: String, kind: ClipKind)] = [
            ("kind:image", .image),
            ("kind:text", .text),
            (":img", .image),
            (":txt", .text),
        ]

        for (token, kind) in tokens where lower.hasPrefix(token) {
            let afterToken = trimmed.index(trimmed.startIndex, offsetBy: token.count)
            // The token must end the string or be followed by whitespace — so
            // `:imgx` / `:txterm` are NOT tokens (they pass through as search).
            if afterToken == trimmed.endIndex {
                return (kind, "")
            }
            let next = trimmed[afterToken]
            guard next == " " || next == "\t" else { continue }
            // Strip the token and exactly one following space, keep the rest verbatim.
            let residual = String(trimmed[trimmed.index(after: afterToken)...])
            return (kind, residual)
        }
        return (nil, query)
    }

    public var selectedItem: HistoryItem? {
        guard filtered.indices.contains(selectedIndex) else { return nil }
        return filtered[selectedIndex]
    }

    /// The clip the detail pane / action menu should show: the cursor item in
    /// the list, or the captured target once we're acting on one.
    public var detailItem: HistoryItem? {
        mode == .list ? selectedItem : actionItem
    }

    public var isEmpty: Bool { allItems.isEmpty }

    // MARK: - Navigation

    public func moveUp() {
        switch mode {
        case .list: stepList(by: -1)
        case .actions: stepAction(by: -1)
        case .custom, .edit: break
        }
    }

    public func moveDown() {
        switch mode {
        case .list: stepList(by: 1)
        case .actions: stepAction(by: 1)
        case .custom, .edit: break
        }
    }

    /// ↵ — list: paste the selected clip; actions: run/open the highlighted
    /// entry; custom: run the one-off prompt.
    public func confirm() {
        switch mode {
        case .list:
            guard let item = selectedItem else { return }
            logPaste(item, via: "return")
            onBuiltin(.paste, item)
        case .actions:
            runSelectedAction()
        case .custom:
            runCustom()
        case .edit:
            break // ⌘↵ runs (see runEdit); plain ↵ adds a newline in the editor
        }
    }

    /// Paste the clip at `index` in the filtered list (1-based positions map to
    /// index-1 by the caller). Used by ⌘1–9 quick-paste. No-op if out of range.
    public func pasteItem(at index: Int) {
        guard mode == .list, filtered.indices.contains(index) else { return }
        logPaste(filtered[index], via: "quickKey")
        onBuiltin(.paste, filtered[index])
    }

    /// Paste from a list-row click (distinct `via` from the keyboard ↵ path,
    /// which routes through `confirm()`).
    public func clickPaste(at index: Int) {
        guard mode == .list, filtered.indices.contains(index) else { return }
        selectedIndex = index
        logPaste(filtered[index], via: "click")
        onBuiltin(.paste, filtered[index])
    }

    /// Record a `paste` usage event (no-op when the journal is off). Logs only
    /// the paste method and the clip *kind* — never the clip contents.
    private func logPaste(_ item: HistoryItem, via: String) {
        var fields: [String: Any] = ["via": via, "clipKind": item.kind.rawValue]
        // When a search query is active, also record where the chosen clip sat in
        // the filtered results — contentless (Ints only), for a search-quality MRR.
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let idx = filtered.firstIndex(where: { $0.id == item.id }) {
            fields["queryLength"] = q.count          // consistent with the `search` event
            fields["rank"] = idx + 1                 // 1-based position in the filtered list
            fields["resultCount"] = filtered.count   // context: rank 1 of 1 ≠ rank 1 of 40
        }
        log("paste", fields)
    }

    /// Run the Nth saved action (0-based) among the currently visible menu items —
    /// built-ins and Custom… are not counted (⌘1 = first saved action). No-op if
    /// out of range or not in `.actions` mode. Mirrors `pasteItem(at:)`.
    public func runSavedAction(at index: Int) {
        guard mode == .actions, let item = actionItem else { return }
        let saved: [Action] = filteredMenuItems.compactMap {
            if case .saved(let a) = $0 { return a } else { return nil }
        }
        guard saved.indices.contains(index) else { return }
        onRunAction(saved[index], item)
    }

    // MARK: - Quick-key numbers (⌘1–9 discoverability)

    /// The maximum quick-key digit (⌘1…⌘9). ⌘0 / ⌘10+ aren't bound.
    public static let maxQuickKey = 9

    /// The ⌘-digit (1–9) for a list row at `index` in display order, or nil if
    /// the row has no bound shortcut (rows 10+). Mirrors `pasteItem(at:)`'s
    /// 0-based indexing → 1-based digit.
    public static func listQuickKey(forRowAt index: Int) -> Int? {
        guard index >= 0, index < maxQuickKey else { return nil }
        return index + 1
    }

    /// The ⌘-digit (1–9) for the action-menu row at `index`, or nil if it's a
    /// built-in / Custom… / divider, or a saved action past the 9th. Counts only
    /// `.saved` entries (in `items` order), matching `runSavedAction(at:)`.
    public static func actionQuickKey(forRowAt index: Int, in items: [ActionMenuItem]) -> Int? {
        guard items.indices.contains(index), case .saved = items[index] else { return nil }
        // Position among saved entries up to and including this row.
        let savedSoFar = items[...index].reduce(0) { count, entry in
            if case .saved = entry { return count + 1 } else { return count }
        }
        guard savedSoFar <= maxQuickKey else { return nil }
        return savedSoFar
    }

    /// esc — actions/custom/edit: step back; list: close the panel.
    public func cancel() {
        switch mode {
        case .actions: returnToList()
        case .custom, .edit: backToActions()
        case .list: onDismiss()
        }
    }

    /// Open the action menu on the clip with `focusId` (the ⌃⇧V captured
    /// selection), falling back to the first displayed clip if not found / nil.
    /// Targets by id so pinned-first ordering doesn't hijack the selection.
    public func openActionsOnTop(focusId: UUID?) {
        guard !filtered.isEmpty else { return }
        selectedIndex = focusId.flatMap { id in filtered.firstIndex(where: { $0.id == id }) } ?? 0
        tab()
    }

    /// Fold a clip created while the panel is open (a detail-pane ⌘C of part of
    /// a clip) into the live list, *without* moving the highlight off the clip
    /// the user is reading. `id` is the originally-selected clip's id, captured
    /// before the insert; selection is resolved back to it by id afterwards
    /// (falling back to the top row if it's gone).
    ///
    /// No-op outside list mode so it never disturbs the action/custom/edit
    /// machinery. The store has already deduped by content hash, so a clip equal
    /// to an existing one arrives as that bumped item (same id) — we replace in
    /// place rather than duplicate.
    public func insertCopiedClip(_ item: HistoryItem, keepingSelectionOnID id: UUID?) {
        guard mode == .list else { return }

        // Upsert by id: a dedupe-bump returns the existing clip's id, so drop any
        // stale copy before inserting at the front (recency order, newest first).
        allItems.removeAll { $0.id == item.id }
        allItems.insert(item, at: 0)
        allItems = Self.ordered(allItems)

        // Rebuild the filtered view for the current query, then re-pin selection
        // to the original clip by id (an active search may exclude the new clip,
        // and pinned-first ordering can shift indices — id is the stable key).
        rebuildFiltered()
        selectedIndex = id.flatMap { wanted in filtered.firstIndex(where: { $0.id == wanted }) } ?? 0
    }

    /// Recompute `filtered` from `allItems` honoring the current query — the
    /// shared body of `refreshClips`'s sync pass, without touching the cursor or
    /// scheduling the async deep search (the caller re-pins selection by id).
    private func rebuildFiltered() {
        let (kind, q) = Self.parseKindFilter(query)
        let candidates = kind.map { k in allItems.filter { $0.kind == k } } ?? allItems
        filtered = q.isEmpty ? candidates : FuzzyMatcher.rank(candidates, query: q)
    }

    /// ⇥ — list: open the action menu; actions: edit-before-run the highlighted
    /// saved action; edit: advance to the next step.
    public func tab() {
        switch mode {
        case .list:
            guard let item = selectedItem else { return }
            actionItem = item
            menuItems = buildMenu(for: item)
            // Hand the search field to the action list: stash the clip query
            // (and the cursor's clip id, so Esc can restore the cursor), clear
            // it, then filter the menu (empty query → all).
            savedClipQuery = query
            savedClipID = item.id
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

    /// Built-ins for the clip kind, plus the per-item Pin/Unpin entry (inserted
    /// before Delete), then Custom… + the saved actions. Image clips offer these
    /// too: a saved/custom AI step takes the image as input (first step must be
    /// AI — enforced by `ActionRunner`).
    private func buildMenu(for item: HistoryItem) -> [ActionMenuItem] {
        var entries: [ActionMenuItem] = BuiltinAction.entries(for: item.kind).map { .builtin($0) }
        let pin: ActionMenuItem = .builtin(item.isPinned ? .unpin : .pin)
        if let deleteIdx = entries.firstIndex(where: { $0.id == "builtin.delete" }) {
            entries.insert(pin, at: deleteIdx)
        } else {
            entries.append(pin)
        }
        entries.append(.custom)
        entries += actions.map { .saved($0) }
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

    /// Build the prompt for a one-off Custom… run. For text clips: honor
    /// `{{TEXT}}` if present, else append the clip after the instruction
    /// (ported from AI Replace). For image clips there is no text to splice —
    /// the image is fed to the AI directly — so the instruction is used as-is.
    public static func buildCustomPrompt(_ userInput: String, isImage: Bool = false) -> String {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if isImage { return trimmed }
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
            Step(type: .ai, prompt: Self.buildCustomPrompt(trimmed, isImage: item.kind == .image)),
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
    public func runEdit() {
        guard let item = actionItem, var action = editAction else { return }
        commitEditBody(into: &action)
        onRunAction(action, item)
    }

    public var editStepCount: Int { editAction?.steps.count ?? 0 }

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
        // refreshClips reset the cursor to 0; restore it to the clip we entered
        // on (by id, since pinned-first ordering / filtering can shift indices).
        // Falls back to 0 if that clip is gone (e.g. deleted while in actions).
        if let id = savedClipID, let idx = filtered.firstIndex(where: { $0.id == id }) {
            selectedIndex = idx
        }
        savedClipID = nil
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

        // A leading `:img` / `kind:image` (or `:txt` / `kind:text`) token
        // restricts the candidate set to that kind; the rest is the residual
        // query, searched normally over the kind-filtered clips. List mode only —
        // this is the only place clip search runs (action search is separate).
        let (kind, q) = Self.parseKindFilter(query)
        let candidates = kind.map { k in allItems.filter { $0.kind == k } } ?? allItems

        // Empty (residual) query: show all in pinned-first order (don't run
        // through the fuzzy ranker, which would rank by match quality and
        // interleave pins).
        guard !q.isEmpty else {
            filtered = candidates
            selectedIndex = 0
            // Don't journal the empty query (clearing the field / opening the panel).
            searchLogTask?.cancel()
            searchLogTask = nil
            return
        }

        // Sync pass: instant result from bounded prefix.
        let syncResult = FuzzyMatcher.rank(candidates, query: q)
        filtered = syncResult
        selectedIndex = 0
        scheduleSearchLog(queryLength: q.count, resultCount: syncResult.count)

        // Async deep pass: scan full text of long clips that didn't sync-match.
        // Task.detached is required — an unqualified Task { } inherits @MainActor
        // and would block the main thread for the entire scan.
        let syncIDs = Set(syncResult.map(\.id))
        let deepCandidates = candidates.filter { item in
            guard !syncIDs.contains(item.id),
                  let text = item.text,
                  text.utf8.count > FuzzyMatcher.searchPrefixLimit else { return false }
            return true
        }
        guard !deepCandidates.isEmpty else { return }

        let allItemsSnapshot = candidates
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

    /// Record one `search` usage event per settled query (≈400ms debounce so a
    /// fast typist produces one event per query, not one per keystroke). Logs the
    /// query *length* and the result count — **never the query characters**.
    private func scheduleSearchLog(queryLength: Int, resultCount: Int) {
        searchLogTask?.cancel()
        searchLogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.log("search", ["queryLength": queryLength, "resultCount": resultCount])
        }
    }

    /// Called on the main actor after the off-actor deep scan completes. Validates
    /// that the query hasn't changed since the scan started, then merges results.
    @MainActor
    private func mergeDeepResults(
        deepMatchIDs: Set<UUID>, syncIDs: Set<UUID>,
        snapshot: [HistoryItem], capturedQuery: String
    ) {
        // Compare against the residual of the *current* query so a kind token
        // (`:img foo`) doesn't make this look stale (capturedQuery is the residual).
        guard capturedQuery == Self.parseKindFilter(query).residual, !Task.isCancelled else { return }
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
public enum ClipTime {
    public static func relative(_ date: Date, now: Date = Date()) -> String {
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

    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
}
