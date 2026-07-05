import Combine
import Foundation
import RecallyxCore

/// iOS consumer of the shared `SyncActivityMonitor`. On first launch the local
/// store is empty until CloudKit downloads the user's clips, so the empty view
/// needs to distinguish "nothing to show yet, still syncing" from "genuinely
/// empty". This thin wrapper re-exposes exactly the members `ClipListView`
/// already uses (`isImporting`/`hasSyncedOnce`/`awaitNextImport`) and hands the
/// underlying `activity` monitor to `SettingsView` for the full "Last sync"
/// status line — one observer core, two consumers.
@MainActor
final class SyncStatusMonitor: ObservableObject {
    /// The shared observer core (also drives the Settings "Last sync" line).
    let activity: SyncActivityMonitor

    private var cancellable: AnyCancellable?

    /// True while an initial CloudKit import is in flight — drives "Syncing…".
    var isImporting: Bool { activity.isImporting }

    /// Set once any import event has finished, so a genuinely empty account
    /// eventually shows "No clips" instead of a perpetual spinner.
    var hasSyncedOnce: Bool { activity.hasSyncedOnce }

    init(activity: SyncActivityMonitor? = nil) {
        // Construct the core inside the (main-actor) init body rather than as a
        // default argument — a default arg is evaluated off the actor, which the
        // core's `@MainActor init` can't be called from synchronously.
        let activity = activity ?? SyncActivityMonitor()
        self.activity = activity
        // Republish the core's changes so SwiftUI views observing this wrapper
        // re-render when a sync event lands.
        cancellable = activity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Await the next completed CloudKit `.import` event (or a bounded timeout).
    /// `onParked` fires the instant the waiter is registered — the pull-to-refresh
    /// caller kicks the import there so no completion signal is missed.
    func awaitNextImport(timeout: Duration = .seconds(8), onParked: (() -> Void)? = nil) async {
        await activity.awaitNextImport(timeout: timeout, onParked: onParked)
    }
}
