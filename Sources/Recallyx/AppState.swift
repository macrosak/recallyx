import Foundation

/// Menu-bar status. Mirrors AI Replace's `CorrectionStatus` but framed around
/// the clipboard manager: idle is the resting state, working covers a running
/// action, error surfaces the last failure.
enum AppStatus: Equatable {
    case idle
    case working
    case success
    case error(String)

    var iconSystemName: String {
        switch self {
        case .idle: return "doc.on.clipboard"
        case .working: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var menuLabel: String {
        switch self {
        case .idle: return "Ready"
        case .working: return "Working…"
        case .success: return "Done"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .idle
    @Published var lastError: String = ""
    /// Number of clips currently in history — shown in the menu-bar dropdown.
    @Published var historyCount: Int = 0

    private var flashTask: Task<Void, Never>?

    func flash(_ status: AppStatus, resetAfter seconds: TimeInterval = 1.5) {
        flashTask?.cancel()
        self.status = status
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.status = .idle
        }
    }
}
