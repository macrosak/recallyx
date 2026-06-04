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
    }

    @Published var query: String = "" {
        didSet { refresh() }
    }
    @Published private(set) var filtered: [HistoryItem]
    @Published var selectedIndex: Int = 0
    @Published private(set) var mode: Mode = .list
    @Published private(set) var actionEntries: [BuiltinAction] = []
    @Published var actionIndex: Int = 0

    private(set) var allItems: [HistoryItem]
    private let onBuiltin: (BuiltinAction, HistoryItem) -> Void
    private let onDismiss: () -> Void

    init(
        items: [HistoryItem],
        onBuiltin: @escaping (BuiltinAction, HistoryItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.allItems = items
        self.filtered = items
        self.onBuiltin = onBuiltin
        self.onDismiss = onDismiss
    }

    var selectedItem: HistoryItem? {
        guard filtered.indices.contains(selectedIndex) else { return nil }
        return filtered[selectedIndex]
    }

    var isEmpty: Bool { allItems.isEmpty }

    // MARK: - Navigation

    func moveUp() {
        switch mode {
        case .list: stepList(by: -1)
        case .actions: stepAction(by: -1)
        }
    }

    func moveDown() {
        switch mode {
        case .list: stepList(by: 1)
        case .actions: stepAction(by: 1)
        }
    }

    /// ↵ — list: paste the selected clip; actions: run the highlighted action.
    func confirm() {
        switch mode {
        case .list:
            guard let item = selectedItem else { return }
            onBuiltin(.paste, item)
        case .actions:
            runSelectedAction()
        }
    }

    /// esc — actions: back to the list; list: close the panel.
    func cancel() {
        switch mode {
        case .actions: mode = .list
        case .list: onDismiss()
        }
    }

    /// ⇥ — list: open the action menu for the selected clip. (Edit-before-run
    /// from within the action menu lands in a Phase 2 commit.)
    func tab() {
        switch mode {
        case .list:
            guard let item = selectedItem else { return }
            actionEntries = BuiltinAction.entries(for: item.kind)
            actionIndex = 0
            mode = .actions
        case .actions:
            break
        }
    }

    // MARK: - Running

    private func runSelectedAction() {
        guard let item = selectedItem, actionEntries.indices.contains(actionIndex) else { return }
        let action = actionEntries[actionIndex]
        if action == .delete {
            onBuiltin(.delete, item)
            removeLocally(item)
            mode = .list
        } else {
            // Controller performs the action and dismisses the panel.
            onBuiltin(action, item)
        }
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
        guard !actionEntries.isEmpty else { return }
        actionIndex = min(max(actionIndex + delta, 0), actionEntries.count - 1)
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
