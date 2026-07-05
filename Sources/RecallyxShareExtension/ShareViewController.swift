import RecallyxCore
import UIKit
import UniformTypeIdentifiers

/// The Recallyx share extension.
///
/// A deliberately tiny, fast path: read the shared **text** (or a shared URL as
/// its string) from the extension's input items, write one clip into the shared
/// app-group Core Data store via `ShareClipWriter`, flash a checkmark, and
/// dismiss. It never presents a compose form — sharing to Recallyx should feel
/// like "saved" the instant you tap it.
///
/// It uses a plain `UIViewController` (not the clunky, semi-deprecated
/// `SLComposeServiceViewController`) and a `ShareClipWriter` (not `HistoryStore`)
/// so the whole process stays lean — see `ShareClipWriter` for why loading the
/// full history / a CloudKit-mirrored store in an extension is the wrong move,
/// and how the local write still reaches the fleet via persistent history.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpUI()
        extractSharedText { [weak self] text in
            guard let self else { return }
            guard let text, let clip = CapturedClip.forText(
                text,
                sourceAppName: "Share Sheet",
                sourceDeviceName: UIDevice.current.name,
                sourceDeviceType: "iphone"
            ) else {
                self.finish(success: false, message: "Nothing to save")
                return
            }
            // Save off the main thread; the writer opens its own store + context.
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = self.writeClip(clip)
                DispatchQueue.main.async {
                    self.finish(
                        success: outcome != .failed,
                        message: outcome == .failed ? "Couldn't save" : "Saved to Recallyx"
                    )
                }
            }
        }
    }

    // MARK: - Store write

    /// Open the app-group store and save the clip. Returns `.failed` if the
    /// shared container can't be resolved (an unprovisioned build).
    private func writeClip(_ clip: CapturedClip) -> ShareClipWriter.Outcome {
        guard let base = ShareClipWriter.appGroupBaseURL() else { return .failed }
        return ShareClipWriter(baseURL: base).save(clip)
    }

    // MARK: - Input extraction

    /// Pull the first usable string from the extension's input items: prefer
    /// plain text, fall back to a shared URL's absolute string. Calls back on the
    /// main queue with the text, or `nil` when nothing text-like was shared.
    private func extractSharedText(_ completion: @escaping (String?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        let textType = UTType.plainText.identifier
        let urlType = UTType.url.identifier

        // Prefer a text attachment; otherwise the first URL attachment.
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            textProvider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
                DispatchQueue.main.async { completion(Self.string(from: item)) }
            }
            return
        }
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            urlProvider.loadItem(forTypeIdentifier: urlType, options: nil) { item, _ in
                DispatchQueue.main.async { completion(Self.string(from: item)) }
            }
            return
        }
        completion(nil)
    }

    /// Coerce a loaded item (String / URL / Data / NSAttributedString) into a
    /// plain string.
    private static func string(from item: NSSecureCoding?) -> String? {
        switch item {
        case let s as String: return s
        case let url as URL: return url.absoluteString
        case let attr as NSAttributedString: return attr.string
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    // MARK: - UI

    private func setUpUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .systemBlue
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        iconView.image = UIImage(systemName: "doc.on.clipboard")
        card.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.textAlignment = .center
        label.text = "Saving…"
        card.addSubview(label)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 220),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
    }

    /// Flash the outcome, then complete (or cancel) the extension request.
    private func finish(success: Bool, message: String) {
        label.text = message
        iconView.image = UIImage(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
        iconView.tintColor = success ? .systemGreen : .systemRed

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            if success {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                self.extensionContext?.cancelRequest(
                    withError: NSError(domain: "io.github.macrosak.recallyx.share", code: 1)
                )
            }
        }
    }
}
