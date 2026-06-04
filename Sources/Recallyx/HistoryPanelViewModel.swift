import Foundation

/// Drives the ⌘⇧V history panel: the search query, the ranked/filtered list,
/// and the keyboard cursor. The action-menu mode is layered on in a later
/// commit; for now the panel is list + detail with Enter-to-paste.
@MainActor
final class HistoryPanelViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { refresh() }
    }
    @Published private(set) var filtered: [HistoryItem]
    @Published var selectedIndex: Int = 0

    private let allItems: [HistoryItem]
    private let onPaste: (HistoryItem) -> Void
    private let onDismiss: () -> Void

    init(
        items: [HistoryItem],
        onPaste: @escaping (HistoryItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.allItems = items
        self.filtered = items
        self.onPaste = onPaste
        self.onDismiss = onDismiss
    }

    var selectedItem: HistoryItem? {
        guard filtered.indices.contains(selectedIndex) else { return nil }
        return filtered[selectedIndex]
    }

    var isEmpty: Bool { allItems.isEmpty }

    func moveUp() { step(by: -1) }
    func moveDown() { step(by: 1) }

    /// ↵ — paste the selected clip.
    func confirm() {
        guard let item = selectedItem else { return }
        onPaste(item)
    }

    /// esc — close the panel.
    func cancel() {
        onDismiss()
    }

    private func refresh() {
        filtered = FuzzyMatcher.rank(allItems, query: query)
        selectedIndex = 0
    }

    private func step(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(next, 0), filtered.count - 1)
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
