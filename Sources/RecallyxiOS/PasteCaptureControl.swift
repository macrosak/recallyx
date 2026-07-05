import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A `UIPasteControl` wrapped for SwiftUI. Tapping it performs a system paste
/// **without** triggering iOS's clipboard-access alert (that's the whole point
/// of `UIPasteControl` over reading `UIPasteboard.general` directly), reads the
/// pasted **string**, and hands it to `onPasteText`. Non-text pastes are ignored
/// gracefully. The control auto-enables only when the pasteboard holds content
/// its target's `pasteConfiguration` accepts (text here).
///
/// Rendered as a **labelled capsule** (icon + "Paste") — this is the app's only
/// capture affordance, so it must be prominent. The original icon-only control
/// in the nav-bar toolbar collapsed to an invisible zero-size button (a plain
/// wrapping `UIView` reports no intrinsic size). The fix: the container forwards
/// the control's `intrinsicContentSize`, the representable answers `sizeThatFits`,
/// and the caller gives it an explicit frame, so SwiftUI lays it out at a real
/// size. **Note:** `UIPasteControl` content is redacted from Simulator screen
/// captures for security — it looks blank in screenshots but renders fully on
/// device.
struct PasteCaptureControl: UIViewRepresentable {
    /// Called on the main actor with the pasted string. Text only for now —
    /// image payloads don't sync between devices yet.
    var onPasteText: (String) -> Void

    func makeUIView(context: Context) -> PasteCaptureContainer {
        let container = PasteCaptureContainer()
        container.onPasteText = onPasteText

        var config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        let control = UIPasteControl(configuration: config)
        // Route the paste to our container (which declares what it accepts and
        // implements `paste(itemProviders:)`), not the ambient responder chain.
        control.target = container
        control.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(control)
        container.control = control
        // Pin the control to fill the container so it takes the explicit frame
        // the SwiftUI side gives us (a plain container otherwise reports no
        // intrinsic size, which collapsed the button to nothing in the toolbar).
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: PasteCaptureContainer, context: Context) {
        uiView.onPasteText = onPasteText
    }

    /// Report the control's real size so SwiftUI doesn't collapse the wrapped
    /// `UIView` (a plain container reports `noIntrinsicMetric`, which is what
    /// made the button invisible in the toolbar).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteCaptureContainer, context: Context) -> CGSize? {
        uiView.control?.intrinsicContentSize
    }
}

/// The `UIPasteControl`'s target. Declares that it accepts text (so the control
/// enables when the pasteboard has a string) and turns a paste into a string.
final class PasteCaptureContainer: UIView {
    var onPasteText: ((String) -> Void)?
    weak var control: UIPasteControl?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Enable the control whenever the pasteboard holds text-like content.
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.plainText.identifier,
                UTType.utf8PlainText.identifier,
                UTType.text.identifier,
                UTType.url.identifier,
            ]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Forward the paste control's intrinsic size so Auto Layout (and SwiftUI's
    /// `sizeThatFits`) has a real size to work with instead of collapsing.
    override var intrinsicContentSize: CGSize {
        control?.intrinsicContentSize ?? super.intrinsicContentSize
    }

    /// `UIPasteControl` calls this when tapped. Load the first string off the
    /// providers off-thread, then hop to the main actor to add it to the store.
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return  // no text on the pasteboard — ignore non-text pastes gracefully
        }
        provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor in
                self?.onPasteText?(text)
            }
        }
    }
}
