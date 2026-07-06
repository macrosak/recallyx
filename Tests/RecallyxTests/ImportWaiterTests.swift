import Foundation
import Testing
@testable import RecallyxCore

/// The wait/timeout core behind the iOS pull-to-refresh spinner. Since
/// `NSPersistentCloudKitContainer.Event` isn't publicly constructable, the
/// SyncStatusMonitor forwards import-completion into `ImportWaiter.signal()`; the
/// spinner's `wait` is driven directly here with an injected `sleep`.
@MainActor
@Suite("ImportWaiter")
struct ImportWaiterTests {

    /// A `signal()` (import finished) before the timeout resolves the wait as
    /// signaled (true).
    @Test func signalBeforeTimeout_returnsTrue() async {
        let waiter = ImportWaiter()
        // Never-returning timeout, so only the signal can resolve the wait.
        let task = Task { @MainActor in
            await waiter.wait(timeout: .seconds(60)) { _ in
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Let the wait park its continuation before signaling.
        try? await Task.sleep(for: .milliseconds(30))
        waiter.signal()
        #expect(await task.value == true)
    }

    /// With no signal, an elapsed timeout resolves the wait as timed-out (false).
    /// The injected `sleep` returns immediately so the test doesn't actually wait.
    @Test func timeoutWithoutSignal_returnsFalse() async {
        let waiter = ImportWaiter()
        let result = await waiter.wait(timeout: .seconds(8)) { _ in }  // instant timeout
        #expect(result == false)
    }

    /// `signal()` with nothing parked is a harmless no-op (a stray import
    /// completion when no pull is in flight).
    @Test func signalWithNoWaiters_isNoOp() {
        let waiter = ImportWaiter()
        waiter.signal()   // must not crash / double-resume
    }

    /// Park-before-signal ordering (the pull-to-refresh fix). The awaited work is
    /// kicked from `onParked`, which runs the instant the waiter is registered —
    /// so even a signal that races back immediately is captured, not dropped into
    /// an empty waiter set. Here `onParked` signals synchronously; the wait must
    /// still resolve `true` (never fall through to the timeout).
    @Test func onParkedKickSignalsImmediately_isCaptured() async {
        let waiter = ImportWaiter()
        let result = await waiter.wait(
            timeout: .seconds(60),
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) },   // never times out
            onParked: { waiter.signal() }                                // fires while parked
        )
        #expect(result == true)
    }

    /// Ordering contrast: a signal fired BEFORE any waiter is parked is dropped
    /// (the guard in `signal()`), so a later `wait` with an instant timeout
    /// resolves `false`. This is the race the `onParked` kick exists to avoid.
    @Test func signalBeforePark_isDropped() async {
        let waiter = ImportWaiter()
        waiter.signal()   // nothing parked yet → dropped
        let result = await waiter.wait(timeout: .seconds(4)) { _ in }   // instant timeout
        #expect(result == false)
    }

    /// One signal releases every parked waiter (e.g. two overlapping pulls).
    @Test func signalReleasesAllWaiters() async {
        let waiter = ImportWaiter()
        let a = Task { @MainActor in
            await waiter.wait(timeout: .seconds(60)) { _ in try? await Task.sleep(for: .seconds(60)) }
        }
        let b = Task { @MainActor in
            await waiter.wait(timeout: .seconds(60)) { _ in try? await Task.sleep(for: .seconds(60)) }
        }
        try? await Task.sleep(for: .milliseconds(30))
        waiter.signal()
        #expect(await a.value == true)
        #expect(await b.value == true)
    }
}
