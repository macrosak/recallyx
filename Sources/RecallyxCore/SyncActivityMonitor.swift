import CoreData
import Foundation

/// The kind of CloudKit mirroring event, mirrored into a constructable enum so
/// the reducer is unit-testable without a real `NSPersistentCloudKitContainer.Event`
/// (which isn't publicly constructable).
public enum CloudKitEventKind: Sendable {
    case setup
    case `import`
    case export
    case other
}

/// The full, testable state the monitor tracks. Kept a value type with a pure
/// reducer so the notification-driven logic is verifiable without CloudKit.
public struct SyncActivityState: Equatable, Sendable {
    /// Last time an export event completed successfully (this device pushed).
    public var lastExportSuccess: Date?
    /// Last time an import event completed successfully (this device pulled).
    public var lastImportSuccess: Date?
    /// The most recent failed event, category-only (never a message).
    public var lastError: SyncActivityError?
    /// True while any mirroring event is in flight.
    public var isActive: Bool = false
    /// True while an import is in flight (drives the iOS "Syncing…" state).
    public var isImporting: Bool = false
    /// Set once any import event has finished (genuinely-empty vs still-syncing).
    public var hasSyncedOnce: Bool = false

    public init() {}

    /// Pure state transition for one CloudKit event. `ended` is `endDate != nil`;
    /// `succeeded` is the event's success flag; `errorCategory` is a content-free
    /// category when the event failed. Returns the new state and whether an import
    /// just completed (so the observer can release pull-to-refresh waiters).
    public func reduced(
        kind: CloudKitEventKind,
        ended: Bool,
        succeeded: Bool,
        errorCategory: String?,
        at: Date
    ) -> (state: SyncActivityState, importCompleted: Bool) {
        var next = self
        next.isActive = !ended

        if kind == .import {
            next.isImporting = !ended
        }

        var importCompleted = false
        guard ended else { return (next, false) }

        if kind == .import {
            next.hasSyncedOnce = true
            importCompleted = true
        }

        if succeeded {
            switch kind {
            case .export: next.lastExportSuccess = at
            case .import: next.lastImportSuccess = at
            case .setup, .other: break
            }
        } else if let errorCategory {
            next.lastError = SyncActivityError(category: errorCategory, at: at)
        }

        return (next, importCompleted)
    }
}

/// **The single CloudKit sync observer** for both platforms. Watches
/// `NSPersistentCloudKitContainer.eventChangedNotification` and keeps a
/// content-free record of the last successful export/import, the last error
/// (CATEGORY only), and whether an event is in flight.
///
/// The mac Settings/menu-bar and the iOS `SyncStatusMonitor` are both consumers
/// of this one observer core. Clock + notification center are injectable so the
/// reducer path is hermetically testable (mirrors `UsageJournal`'s seams).
@MainActor
public final class SyncActivityMonitor: ObservableObject {
    @Published public private(set) var state = SyncActivityState()

    public var lastExportSuccess: Date? { state.lastExportSuccess }
    public var lastImportSuccess: Date? { state.lastImportSuccess }
    public var lastError: SyncActivityError? { state.lastError }
    public var isActive: Bool { state.isActive }
    public var isImporting: Bool { state.isImporting }
    public var hasSyncedOnce: Bool { state.hasSyncedOnce }

    private let now: () -> Date
    private var observer: NSObjectProtocol?

    /// Parks pull-to-refresh callers until the next import completes (or times
    /// out) — `NSPersistentCloudKitContainer` has no fetch-now API.
    private let waiter = ImportWaiter()

    public init(
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
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

    /// Convenience for hermetic tests: apply an event without a real
    /// `NSPersistentCloudKitContainer.Event`.
    public func apply(
        kind: CloudKitEventKind,
        ended: Bool,
        succeeded: Bool = true,
        errorCategory: String? = nil,
        at: Date? = nil
    ) {
        let (next, importCompleted) = state.reduced(
            kind: kind,
            ended: ended,
            succeeded: succeeded,
            errorCategory: errorCategory,
            at: at ?? now()
        )
        state = next
        if importCompleted { waiter.signal() }
    }

    /// Await the next completed CloudKit `.import` event, or return after
    /// `timeout` if none arrives. Drives pull-to-refresh; safe when sync is off
    /// (it simply times out). `timeout` is injectable for tests. `onParked` runs
    /// the instant the waiter is registered, before suspending — callers kick the
    /// import from there so a fast completion can't signal into an empty waiter.
    public func awaitNextImport(timeout: Duration = .seconds(8), onParked: (() -> Void)? = nil) async {
        await waiter.wait(timeout: timeout, onParked: onParked)
    }

    private func handle(_ note: Notification) {
        guard
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        else { return }

        let kind = Self.kind(for: event.type)
        let ended = event.endDate != nil
        let category = ended && !event.succeeded ? Self.errorCategory(event.error) : nil
        apply(
            kind: kind,
            ended: ended,
            succeeded: event.succeeded,
            errorCategory: category,
            at: event.endDate ?? now()
        )
    }

    static func kind(for type: NSPersistentCloudKitContainer.EventType) -> CloudKitEventKind {
        switch type {
        case .setup: return .setup
        case .import: return .import
        case .export: return .export
        @unknown default: return .other
        }
    }

    /// Reduce an error to a content-free category: a CKError code name for
    /// CloudKit errors, else `<domain>#<code>`. **Never** the message.
    static func errorCategory(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        let ns = error as NSError
        if ns.domain == "CKErrorDomain" {
            return "CKError.\(ckErrorName(ns.code))"
        }
        return "\(ns.domain)#\(ns.code)"
    }

    /// Names for every `CKError.Code` case (raw values 1...36, stable per Apple's
    /// CloudKit framework), else the raw value. RecallyxCore doesn't import
    /// CloudKit (only Foundation/CryptoKit/FoundationModels/Vision/Security/os —
    /// see CLAUDE.md), so this is a hardcoded `Int -> String` table rather than
    /// switching on `CKError.Code` itself; the codes are a stable public ABI, so
    /// hardcoding them carries no real drift risk. Content-free by construction.
    private static func ckErrorName(_ code: Int) -> String {
        switch code {
        case 1: return "internalError"
        case 2: return "partialFailure"
        case 3: return "networkUnavailable"
        case 4: return "networkFailure"
        case 5: return "badContainer"
        case 6: return "serviceUnavailable"
        case 7: return "requestRateLimited"
        case 8: return "missingEntitlement"
        case 9: return "notAuthenticated"
        case 10: return "permissionFailure"
        case 11: return "unknownItem"
        case 12: return "invalidArguments"
        case 13: return "resultsTruncated"
        case 14: return "serverRecordChanged"
        case 15: return "serverRejectedRequest"
        case 16: return "assetFileNotFound"
        case 17: return "assetFileModified"
        case 18: return "incompatibleVersion"
        case 19: return "constraintViolation"
        case 20: return "operationCancelled"
        case 21: return "changeTokenExpired"
        case 22: return "batchRequestFailed"
        case 23: return "zoneBusy"
        case 24: return "badDatabase"
        case 25: return "quotaExceeded"
        case 26: return "zoneNotFound"
        case 27: return "limitExceeded"
        case 28: return "userDeletedZone"
        case 29: return "tooManyParticipants"
        case 30: return "alreadyShared"
        case 31: return "referenceViolation"
        case 32: return "managedAccountRestricted"
        case 33: return "participantMayNeedVerification"
        case 34: return "serverResponseLost"
        case 35: return "assetNotAvailable"
        case 36: return "accountTemporarilyUnavailable"
        default: return "\(code)"
        }
    }
}
