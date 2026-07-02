import SwiftUI
import RecallyxCore

/// Placeholder root view: an empty list bound to the synced `HistoryStore`.
/// The real list/search/detail/copy UI lands in a follow-up; this exists so the
/// target compiles and links against RecallyxCore end to end.
struct ContentView: View {
    @EnvironmentObject private var store: HistoryStore

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "doc.on.clipboard",
                        description: Text("Your synced clipboard history will appear here.")
                    )
                } else {
                    List(store.items, id: \.id) { item in
                        Text(item.preview)
                            .lineLimit(2)
                    }
                }
            }
            .navigationTitle("Recallyx")
        }
    }
}
