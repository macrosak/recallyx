import Foundation

/// Awaits the "next event" signal with a timeout — the wait/timeout core behind
/// the iOS pull-to-refresh spinner (CloudKit import completion).
///
/// `NSPersistentCloudKitContainer` has no public "fetch changes now" API, so a
/// pull-to-refresh can only *wait* for the next import to finish (or give up
/// after a bounded timeout). This type parks a continuation resumed either by
/// `signal()` (an import finished) or by the timeout, whichever comes first.
///
/// Split out of the iOS-only `SyncStatusMonitor` into RecallyxCore so the
/// wait/timeout logic is unit-testable without the iOS target and without a
/// fabricated `NSPersistentCloudKitContainer.Event` (which isn't publicly
/// constructable). `@MainActor` so the continuation bookkeeping is serialized.
@MainActor
public final class ImportWaiter {
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init() {}

    /// Await the next `signal()` or `timeout`, whichever comes first. Returns
    /// `true` if a signal arrived, `false` on timeout. `sleep` is injectable so
    /// tests can force an immediate timeout (or a never-returning wait) without a
    /// real clock.
    @discardableResult
    public func wait(
        timeout: Duration,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        let id = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            await sleep(timeout)
            self?.resume(id, with: false)
        }
        // Park before the timeout can fire (both run on the main actor, and this
        // stores synchronously before suspending) so no signal is missed.
        let signaled = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            waiters[id] = cont
        }
        timeoutTask.cancel()
        return signaled
    }

    /// Resume every parked waiter with `true` — an import completed.
    public func signal() {
        guard !waiters.isEmpty else { return }
        let all = waiters
        waiters.removeAll()
        for cont in all.values { cont.resume(returning: true) }
    }

    private func resume(_ id: UUID, with signaled: Bool) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        cont.resume(returning: signaled)
    }
}
