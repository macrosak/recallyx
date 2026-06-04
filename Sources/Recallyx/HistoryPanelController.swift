import AppKit
import SwiftUI

/// Owns the ⌘⇧V history panel: builds it on demand, positions it, captures the
/// source app to paste back into, and routes navigation keys to the view model
/// while letting typed characters reach the search field. Mirrors AI Replace's
/// `LauncherWindowController`.
@MainActor
final class HistoryPanelController {
    private var panel: HistoryPanel?
    private var viewModel: HistoryPanelViewModel?
    private var sourceApp: NSRunningApplication?

    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private let panelSize = NSSize(width: 760, height: 562)

    private let itemsProvider: () -> [HistoryItem]
    private let actionsProvider: () -> [Action]
    private let defaultModelProvider: () -> String
    private let imageURLResolver: (HistoryItem) -> URL?
    /// Perform a built-in action. Returns `true` if the panel should dismiss
    /// afterwards (paste/copy/reveal); `false` keeps it open (delete).
    private let onBuiltin: (BuiltinAction, HistoryItem, NSRunningApplication?) -> Bool
    /// Run a saved action against a clip, then paste the result into `sourceApp`.
    private let onRunAction: (Action, HistoryItem, NSRunningApplication?) -> Void

    init(
        itemsProvider: @escaping () -> [HistoryItem],
        actionsProvider: @escaping () -> [Action] = { [] },
        defaultModelProvider: @escaping () -> String = { ModelCatalog.default },
        imageURLResolver: @escaping (HistoryItem) -> URL?,
        onBuiltin: @escaping (BuiltinAction, HistoryItem, NSRunningApplication?) -> Bool,
        onRunAction: @escaping (Action, HistoryItem, NSRunningApplication?) -> Void = { _, _, _ in }
    ) {
        self.itemsProvider = itemsProvider
        self.actionsProvider = actionsProvider
        self.defaultModelProvider = defaultModelProvider
        self.imageURLResolver = imageURLResolver
        self.onBuiltin = onBuiltin
        self.onRunAction = onRunAction
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { dismiss() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        // Capture the app to paste back into BEFORE we activate ourselves.
        sourceApp = NSWorkspace.shared.frontmostApplication

        let viewModel = HistoryPanelViewModel(
            items: itemsProvider(),
            actions: actionsProvider(),
            onBuiltin: { [weak self] action, item in
                guard let self else { return }
                let app = self.sourceApp
                let shouldDismiss = self.onBuiltin(action, item, app)
                if shouldDismiss { self.dismiss() }
            },
            onRunAction: { [weak self] action, item in
                guard let self else { return }
                let app = self.sourceApp
                self.dismiss()
                self.onRunAction(action, item, app)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        self.viewModel = viewModel

        let root = HistoryPanelView(
            viewModel: viewModel,
            imageURL: { [weak self] in self?.imageURLResolver($0) },
            defaultModel: defaultModelProvider()
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        let panel = HistoryPanel(contentView: hosting, size: panelSize)
        self.panel = panel

        positionOnMouseScreen(panel)
        installEventMonitors()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Log.info("history panel shown items=\(viewModel.filtered.count)")
    }

    func dismiss() {
        guard isVisible else { return }
        uninstallEventMonitors()
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
        Log.debug("history panel dismissed")
    }

    private func positionOnMouseScreen(_ panel: HistoryPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.minX + (visible.width - size.width) / 2
        let y = visible.minY + visible.height * 0.62 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEventMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel { self.dismiss() }
            return event
        }
    }

    private func uninstallEventMonitors() {
        [localKeyMonitor, globalClickMonitor, localClickMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        localKeyMonitor = nil
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    /// Intercept navigation keys; everything else flows to the focused control
    /// (search field, or the ad-hoc AI text editor). Branches on mode so arrows
    /// reach the text editor for cursor movement in custom/edit modes.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let vm = viewModel else { return event }
        let isReturn = event.keyCode == 0x24 || event.keyCode == 0x4C
        let isEsc = event.keyCode == 0x35
        let isTab = event.keyCode == 0x30

        switch vm.mode {
        case .list, .actions:
            switch event.keyCode {
            case 0x7E: vm.moveUp(); return nil
            case 0x7D: vm.moveDown(); return nil
            case 0x24, 0x4C: vm.confirm(); return nil
            case 0x35: vm.cancel(); return nil
            case 0x30: vm.tab(); return nil
            default: return event
            }

        case .custom:
            // ↵ runs the one-off prompt; esc backs out; arrows/typing → editor.
            if isReturn { vm.confirm(); return nil }
            if isEsc { vm.cancel(); return nil }
            if isTab { return nil }
            return event

        case .edit:
            // ⌘↵ runs; plain ↵ adds a newline; ⇥ advances steps; esc cancels.
            if isReturn {
                if event.modifierFlags.contains(.command) { vm.runEdit(); return nil }
                return event
            }
            if isEsc { vm.cancel(); return nil }
            if isTab { vm.tab(); return nil }
            return event
        }
    }
}
