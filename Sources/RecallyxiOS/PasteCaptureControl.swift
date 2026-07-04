import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A `UIPasteControl` wrapped for SwiftUI. Tapping it performs a system paste
/// **without** triggering iOS's clipboard-access alert (that's the whole point
/// of `UIPasteControl` over reading `UIPasteboard.general` directly), reads the
/// pasted **string**, and hands it to `onPasteText`. Non-text pastes are ignored
/// gracefully. The control auto-enables only when the pasteboard holds content
/// its target's `pasteConfiguration` accepts (text here).
struct PasteCaptureControl: UIViewRepresentable {
    /// Called on the main actor with the pasted string. Text only for now —
    /// image payloads don't sync between devices yet.
    var onPasteText: (String) -> Void

    func makeUIView(context: Context) -> PasteCaptureContainer {
        let container = PasteCaptureContainer()
        container.onPasteText = onPasteText

        var config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.cornerStyle = .capsule
        let control = UIPasteControl(configuration: config)
        // Route the paste to our container (which declares what it accepts and
        // implements `paste(itemProviders:)`), not the ambient responder chain.
        control.target = container
        control.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(control)
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
}

/// The `UIPasteControl`'s target. Declares that it accepts text (so the control
/// enables when the pasteboard has a string) and turns a paste into a string.
final class PasteCaptureContainer: UIView {
    var onPasteText: ((String) -> Void)?

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
