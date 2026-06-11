import AppKit

/// Debug-only command channel so scripts (and AI agents doing manual UI
/// testing) can drive the running app: open the panel, type a query, press
/// keys, dump state, snapshot windows. See `scripts/debug.sh` for the sender.
///
/// Active only when launched with `RECALLYX_DEBUG=1` — never in normal runs.
/// Any local process can post distributed notifications, which is why the
/// gate is opt-in per launch.
@MainActor
final class DebugHooks {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RECALLYX_DEBUG"] == "1"
    }

    static let notificationName = Notification.Name("io.github.macrosak.recallyx.debug")

    private let panel: HistoryPanelController
    private let openSettings: () -> Void
    private let historyCount: () -> Int
    private var observer: NSObjectProtocol?

    init(
        panel: HistoryPanelController,
        openSettings: @escaping () -> Void,
        historyCount: @escaping () -> Int
    ) {
        self.panel = panel
        self.openSettings = openSettings
        self.historyCount = historyCount
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { note in
            let cmd = note.userInfo?["cmd"] as? String ?? ""
            let arg = note.userInfo?["arg"] as? String
            Task { @MainActor [weak self] in self?.handle(cmd, arg) }
        }
        Log.info("debug hooks active")
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func handle(_ cmd: String, _ arg: String?) {
        Log.info("debug cmd=\(cmd) arg=\(arg ?? "")")
        switch cmd {
        case "show-panel": panel.show()
        case "show-actions": panel.showOnTopActions()
        case "hide-panel": panel.dismiss()
        case "query": panel.debugSetQuery(arg ?? "")
        case "text": panel.debugSetText(arg ?? "")
        case "key": panel.debugKey(arg ?? "")
        case "open-settings": openSettings()
        case "snapshot": snapshot(to: arg ?? "/tmp/recallyx-snap.png")
        case "state": writeState(to: arg ?? "/tmp/recallyx-state.json")
        default: Log.error("debug: unknown cmd '\(cmd)'")
        }
    }

    /// App-side render of the panel (or frontmost window) via cacheDisplay —
    /// works without any Screen Recording grant. Vibrancy materials render
    /// without the behind-window content, so use `debug.sh shot` (real
    /// screencapture) when the frosted look matters.
    private func snapshot(to path: String) {
        let visible = NSApp.windows.filter { $0.isVisible }
        guard
            let window = visible.first(where: { $0 is HistoryPanel }) ?? NSApp.keyWindow ?? visible.first,
            let view = window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            Log.error("debug: no visible window to snapshot")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            Log.info("debug: snapshot → \(path)")
        } catch {
            Log.error("debug: snapshot write failed: \(error.localizedDescription)")
        }
    }

    private func writeState(to path: String) {
        var state = panel.debugState
        state["historyCount"] = historyCount()
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
