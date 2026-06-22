import AppKit
import RecallyxCore

/// Borderless, floating, frosted panel hosting the history SwiftUI content.
/// Subclass exists to flip `canBecomeKey`/`canBecomeMain` true for a borderless
/// window. Mirrors AI Replace's `LauncherPanel`, widened for the two-pane layout.
final class HistoryPanel: NSPanel {
    init(contentView: NSView, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        host.addSubview(blur)
        host.addSubview(contentView)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: host.topAnchor),
            blur.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: host.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: host.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        self.contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
