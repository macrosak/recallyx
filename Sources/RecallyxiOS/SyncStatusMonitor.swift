import Combine
import CoreData
import Foundation
import RecallyxCore

/// Lightweight CloudKit sync-status watcher. On first launch the local store is
/// empty until CloudKit downloads the user's clips, so the empty view needs to
/// distinguish "nothing to show yet, still syncing" from "genuinely empty".
///
/// Observes `NSPersistentCloudKitContainer.eventChangedNotification` and tracks
/// whether a `.import` event is currently running. Intentionally minimal — no
/// error surfacing UI in the MVP (errors still reach `Log` from core).
@MainActor
final class SyncStatusMonitor: ObservableObject {
    /// True while an initial CloudKit import is in flight and no clips have
    /// arrived yet — drives the "Syncing…" empty state.
    @Published private(set) var isImporting = false

    /// Set once any import event has finished, so a genuinely empty account
    /// eventually shows "No clips" instead of a perpetual spinner.
    @Published private(set) var hasSyncedOnce = false

    private var observer: NSObjectProtocol?

    /// Parks pull-to-refresh callers until the next import completes (or a
    /// timeout). NSPersistentCloudKitContainer can't be told to fetch now, so the
    /// spinner resolves on the next real `.import` completion this monitor sees.
    private let waiter = ImportWaiter()

    init(notificationCenter: NotificationCenter = .default) {
        observer = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handle(note)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func handle(_ note: Notification) {
        guard
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
            event.type == .import
        else { return }

        if event.endDate == nil {
            isImporting = true
        } else {
            isImporting = false
            hasSyncedOnce = true
            // Release any pull-to-refresh spinner waiting on a completed import.
            waiter.signal()
        }
    }

    /// Await the next completed CloudKit `.import` event, or return after
    /// `timeout` if none arrives. Drives pull-to-refresh: the spinner resolves on
    /// a real import completion or a bounded wait. Safe when sync is off — it
    /// simply times out (callers typically short-circuit on `isCloudSyncActive`
    /// before calling this, so the off path is instant). `timeout` is injectable
    /// for tests.
    func awaitNextImport(timeout: Duration = .seconds(8)) async {
        await waiter.wait(timeout: timeout)
    }
}
