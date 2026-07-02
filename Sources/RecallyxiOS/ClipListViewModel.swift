import Combine
import Foundation
import RecallyxCore

/// Thin, iOS-owned list view model. Holds the search `query`, exposes the
/// `filtered` list, and recomputes whenever the query or the store's `items`
/// change. All the ordering/filtering logic lives in the pure
/// `ClipListDisplay` core helper (unit-tested); this is just the reactive glue.
///
/// Deliberately **not** the mac `HistoryPanelViewModel` — that is coupled to the
/// panel's mode machine, action menu, and key routing, none of which maps to an
/// iOS list. The async deep-substring pass is skipped for the MVP (the sync
/// fuzzy pass is enough).
@MainActor
final class ClipListViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var filtered: [HistoryItem] = []

    private let store: HistoryStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: HistoryStore) {
        self.store = store
        recompute()

        // Recompute on either input changing. `$query` fires on keystroke;
        // `store.$items` fires on any store mutation (local pin/delete or a
        // CloudKit merge landing new clips).
        Publishers.CombineLatest($query, store.$items)
            .sink { [weak self] query, items in
                self?.filtered = ClipListDisplay.filter(items, query: query)
            }
            .store(in: &cancellables)
    }

    private func recompute() {
        filtered = ClipListDisplay.filter(store.items, query: query)
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
