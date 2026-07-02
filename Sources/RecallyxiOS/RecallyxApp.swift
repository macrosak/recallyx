import SwiftUI
import RecallyxCore

/// iOS companion app — a placeholder shell for now (an empty list bound to a
/// synced `HistoryStore`). The list/search/detail/copy UI arrives in a follow-up.
///
/// Unlike the mac app there is no `AppDelegate` launch-wiring subtlety (that's a
/// MenuBarExtra lesson): a plain `App` + `WindowGroup` owning one `@StateObject`
/// store is enough.
@main
struct RecallyxApp: App {
    @StateObject private var store = RecallyxApp.makeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }

    /// Build the history store on the shared **app-group container** so a future
    /// Share Extension (separate process) can reach the same Core Data store.
    /// CloudKit sync is on by default on iOS — the synced clips are the app's
    /// entire value. Image reconciliation is off: image payloads don't sync yet,
    /// so a synced image clip has an entity but no local PNG and must be kept.
    ///
    /// If the app-group container can't be resolved (an unsigned simulator build
    /// with no provisioning returns nil) fall back to Application Support — passing
    /// `baseURL: nil` makes `HistoryStore` use its default there — so the
    /// compile/smoke build still runs. A signed device build always resolves the
    /// container.
    private static func makeStore() -> HistoryStore {
        let appGroupID = "group.io.github.macrosak.recallyx"
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Recallyx", isDirectory: true)

        return HistoryStore(
            baseURL: base,   // nil → HistoryStore falls back to Application Support
            cloudSyncEnabled: true,
            reconcileImages: false
        )
    }
}
