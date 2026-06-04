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

    @Published var query: String = "" {
        // Guard against same-value re-writes (SwiftUI re-fires the binding when
        // the search field resigns focus) — an unconditional refresh() would
        // reset selectedIndex to 0 out from under an open action menu.
        didSet { if query != oldValue { refresh() } }
    }
    @Published private(set) var filtered: [HistoryItem]
    @Published var selectedIndex: Int = 0
    @Published private(set) var mode: Mode = .list
    @Published private(set) var menuItems: [ActionMenuItem] = []
    @Published var actionIndex: Int = 0
    /// The clip the action menu / custom / edit modes operate on. Captured when
    /// the menu opens so it stays fixed even if `selectedIndex` shifts.
    @Published private(set) var actionItem: HistoryItem?

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

    init(
        items: [HistoryItem],
        actions: [Action] = [],
        onBuiltin: @escaping (BuiltinAction, HistoryItem) -> Void,
        onRunAction: @escaping (Action, HistoryItem) -> Void = { _, _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.allItems = items
        self.filtered = items
        self.actions = actions
        self.onBuiltin = onBuiltin
        self.onRunAction = onRunAction
        self.onDismiss = onDismiss
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
        case .actions:
            actionItem = nil
            mode = .list
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
            actionIndex = 0
            mode = .actions
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
    private func buildMenu(for item: HistoryItem) -> [ActionMenuItem] {
        var entries: [ActionMenuItem] = BuiltinAction.entries(for: item.kind).map { .builtin($0) }
        if item.kind == .text {
            entries.append(.custom)
            entries += actions.map { .saved($0) }
        }
        return entries
    }

    private var currentEntry: ActionMenuItem? {
        menuItems.indices.contains(actionIndex) ? menuItems[actionIndex] : nil
    }

    // MARK: - Running

    private func runSelectedAction() {
        guard let item = actionItem, let entry = currentEntry else { return }
        switch entry {
        case .builtin(.delete):
            onBuiltin(.delete, item)
            removeLocally(item)
            actionItem = nil
            mode = .list
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
    }

    private func removeLocally(_ item: HistoryItem) {
        allItems.removeAll { $0.id == item.id }
        refresh()
    }

    // MARK: - Internals

    private func refresh() {
        filtered = FuzzyMatcher.rank(allItems, query: query)
        selectedIndex = 0
    }

    private func stepList(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), filtered.count - 1)
    }

    private func stepAction(by delta: Int) {
        guard !menuItems.isEmpty else { return }
        actionIndex = min(max(actionIndex + delta, 0), menuItems.count - 1)
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
