import Foundation
import Testing
@testable import RecallyxCore

/// Pure `SyncStatusLine.text` shapes + the `SyncActivityState` reducer + the
/// content-free error-category mapping. Hermetic — no CloudKit.
@Suite("SyncStatusLine")
struct SyncStatusLineTests {
    // A fixed "now" so relative strings are deterministic.
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func neverSynced_noError_isNil() {
        #expect(SyncStatusLine.text(lastExport: nil, lastImport: nil, lastError: nil, now: now) == nil)
    }

    @Test func exportOnly() {
        let line = SyncStatusLine.text(
            lastExport: now.addingTimeInterval(-120),
            lastImport: nil,
            lastError: nil,
            now: now
        )
        #expect(line == "Last sync: ↑ 2 min ago")
    }

    @Test func importOnly() {
        let line = SyncStatusLine.text(
            lastExport: nil,
            lastImport: now.addingTimeInterval(-300),
            lastError: nil,
            now: now
        )
        #expect(line == "Last sync: ↓ 5 min ago")
    }

    @Test func bothExportAndImport() {
        let line = SyncStatusLine.text(
            lastExport: now.addingTimeInterval(-120),
            lastImport: now.addingTimeInterval(-300),
            lastError: nil,
            now: now
        )
        #expect(line == "Last sync: ↑ 2 min ago · ↓ 5 min ago")
    }

    @Test func errorIsLatest_showsError() {
        let err = SyncActivityError(category: "CKError.networkUnavailable", at: now.addingTimeInterval(-60))
        let line = SyncStatusLine.text(
            lastExport: now.addingTimeInterval(-600),   // older than the error
            lastImport: nil,
            lastError: err,
            now: now
        )
        #expect(line == "Sync error: CKError.networkUnavailable · 1 min ago")
    }

    @Test func errorOlderThanSuccess_showsSuccess() {
        let err = SyncActivityError(category: "CKError.networkUnavailable", at: now.addingTimeInterval(-600))
        let line = SyncStatusLine.text(
            lastExport: now.addingTimeInterval(-120),   // newer than the error
            lastImport: nil,
            lastError: err,
            now: now
        )
        #expect(line == "Last sync: ↑ 2 min ago")
    }
}

@Suite("SyncActivityState reducer")
struct SyncActivityStateTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func importInFlight_thenCompletes() {
        var s = SyncActivityState()
        s = s.reduced(kind: .import, ended: false, succeeded: false, errorCategory: nil, at: t0).state
        #expect(s.isImporting)
        #expect(s.isActive)
        #expect(!s.hasSyncedOnce)

        let r = s.reduced(kind: .import, ended: true, succeeded: true, errorCategory: nil, at: t0)
        #expect(r.importCompleted)
        #expect(!r.state.isImporting)
        #expect(!r.state.isActive)
        #expect(r.state.hasSyncedOnce)
        #expect(r.state.lastImportSuccess == t0)
        #expect(r.state.lastError == nil)
    }

    @Test func exportSuccess_setsExportOnly() {
        let s = SyncActivityState().reduced(
            kind: .export, ended: true, succeeded: true, errorCategory: nil, at: t0
        ).state
        #expect(s.lastExportSuccess == t0)
        #expect(s.lastImportSuccess == nil)
        #expect(!s.isActive)
    }

    @Test func failedEvent_recordsCategoryOnly() {
        let s = SyncActivityState().reduced(
            kind: .export, ended: true, succeeded: false, errorCategory: "CKError.quotaExceeded", at: t0
        ).state
        #expect(s.lastError?.category == "CKError.quotaExceeded")
        #expect(s.lastError?.at == t0)
        #expect(s.lastExportSuccess == nil)   // failure isn't a success
    }

    @Test func setupEvent_doesNotTouchExportOrImport() {
        let s = SyncActivityState().reduced(
            kind: .setup, ended: true, succeeded: true, errorCategory: nil, at: t0
        ).state
        #expect(s.lastExportSuccess == nil)
        #expect(s.lastImportSuccess == nil)
        #expect(!s.isActive)
    }
}

@MainActor
@Suite("SyncActivityMonitor")
struct SyncActivityMonitorTests {
    @Test func applyDrivesPublishedState() {
        let clock = Date(timeIntervalSince1970: 3_000_000)
        let monitor = SyncActivityMonitor(now: { clock })
        monitor.apply(kind: .import, ended: true, succeeded: true)
        #expect(monitor.lastImportSuccess == clock)
        #expect(monitor.hasSyncedOnce)
    }

    @Test func importCompletionReleasesWaiter() async {
        let monitor = SyncActivityMonitor()
        let task = Task { @MainActor in
            await monitor.awaitNextImport(timeout: .seconds(60))
        }
        try? await Task.sleep(for: .milliseconds(30))
        monitor.apply(kind: .import, ended: true, succeeded: true)
        await task.value   // resolves via the import signal, not the timeout
    }

    @Test func ckErrorCategory_named() {
        let e = NSError(domain: "CKErrorDomain", code: 3, userInfo: [NSLocalizedDescriptionKey: "secret content"])
        let cat = SyncActivityMonitor.errorCategory(e)
        #expect(cat == "CKError.networkUnavailable")
        #expect(!cat.contains("secret"))   // never the message
    }

    // Code 2 — the schema-mismatch error the owner actually hit adding a synced
    // field. Regression guard for it rendering as the opaque "CKError.2".
    @Test func ckErrorCategory_partialFailure() {
        let e = NSError(domain: "CKErrorDomain", code: 2)
        #expect(SyncActivityMonitor.errorCategory(e) == "CKError.partialFailure")
    }

    @Test func ckErrorCategory_changeTokenExpired() {
        let e = NSError(domain: "CKErrorDomain", code: 21)
        #expect(SyncActivityMonitor.errorCategory(e) == "CKError.changeTokenExpired")
    }

    @Test func ckErrorCategory_zoneNotFound() {
        let e = NSError(domain: "CKErrorDomain", code: 26)
        #expect(SyncActivityMonitor.errorCategory(e) == "CKError.zoneNotFound")
    }

    @Test func ckErrorCategory_accountTemporarilyUnavailable() {
        let e = NSError(domain: "CKErrorDomain", code: 36)
        #expect(SyncActivityMonitor.errorCategory(e) == "CKError.accountTemporarilyUnavailable")
    }

    @Test func ckErrorCategory_unknownCode_fallsBackToRawNumber() {
        let e = NSError(domain: "CKErrorDomain", code: 999)
        #expect(SyncActivityMonitor.errorCategory(e) == "CKError.999")
    }

    @Test func nonCKError_domainAndCode() {
        let e = NSError(domain: "NSURLErrorDomain", code: -1009)
        #expect(SyncActivityMonitor.errorCategory(e) == "NSURLErrorDomain#-1009")
    }
}
