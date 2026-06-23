import AppKit
import SwiftUI
import RecallyxCore

/// NSViewRepresentable wrapping NSScrollView + NSTextView(usingTextLayoutManager: true)
/// (TextKit 2). TextKit 2 lays out only the visible viewport so a 5 MB string costs
/// roughly the same as a 5 KB one — fixes the ~1 s freeze on arrow-down and panel-open
/// when the top clip is large.
struct LargeTextView: NSViewRepresentable {
    let text: String
    let itemID: UUID
    let theme: RXTheme
    /// Fired after the user copies (⌘C) a non-empty selection in the detail
    /// pane, with the copied substring. The app turns it into a new stack clip
    /// while keeping the original clip selected. Nil disables copy capture.
    var onCopy: ((String) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.onCopy = onCopy
        let textView = CopyInterceptingTextView(usingTextLayoutManager: true)
        textView.onCopy = { [weak coordinator = context.coordinator] copied in
            coordinator?.onCopy?(copied)
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Initial frame width prevents a 0-width first layout pass (TextKit 2 /
        // macOS 13 is sensitive to this — 0-width container causes wrong wrap until
        // the first resize event arrives from SwiftUI).
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = CGRect(x: 0, y: 0, width: 380, height: 0)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        applyAttributes(to: textView, theme: theme)
        // Stamp coordinator so the first updateNSView doesn't re-materialize.
        context.coordinator.lastTheme = theme
        context.coordinator.lastItemID = itemID
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Keep the copy callback current across SwiftUI re-renders (it closes
        // over the viewed clip, which changes as the user navigates).
        context.coordinator.onCopy = onCopy

        guard let textView = scrollView.documentView as? NSTextView else { return }

        let itemChanged = context.coordinator.lastItemID != itemID
        let themeChanged = context.coordinator.lastTheme?.isDark != theme.isDark

        guard itemChanged || themeChanged else { return }

        context.coordinator.lastTheme = theme
        context.coordinator.lastItemID = itemID

        applyAttributes(to: textView, theme: theme)
        if itemChanged {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTheme: RXTheme?
        var lastItemID: UUID?
        /// Held here (not on the text view) so it survives SwiftUI re-renders and
        /// always reflects the currently viewed clip.
        var onCopy: ((String) -> Void)?
    }

    private func applyAttributes(to textView: NSTextView, theme: RXTheme) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(theme.text),
            .paragraphStyle: paragraphStyle,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
    }
}

/// Read-only `NSTextView` that taps ⌘C: it performs the normal system copy
/// (selection → pasteboard) and then reports the copied substring so the app
/// can capture it as a new clip. Fires only for a non-empty selection.
final class CopyInterceptingTextView: NSTextView {
    var onCopy: ((String) -> Void)?

    override func copy(_ sender: Any?) {
        super.copy(sender)
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let nsString = storage.string as NSString
        guard range.location + range.length <= nsString.length else { return }
        onCopy?(nsString.substring(with: range))
    }
}
