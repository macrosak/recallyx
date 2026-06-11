import AppKit
import SwiftUI

/// NSViewRepresentable wrapping NSScrollView + NSTextView(usingTextLayoutManager: true)
/// (TextKit 2). TextKit 2 lays out only the visible viewport so a 5 MB string costs
/// roughly the same as a 5 KB one — fixes the ~1 s freeze on arrow-down and panel-open
/// when the top clip is large.
struct LargeTextView: NSViewRepresentable {
    let text: String
    let theme: RXTheme

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        applyAttributes(to: textView, theme: theme)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let currentStr = textView.string
        let currentTheme = context.coordinator.lastTheme

        let textChanged = currentStr != text
        let themeChanged = currentTheme?.isDark != theme.isDark

        guard textChanged || themeChanged else { return }
        context.coordinator.lastTheme = theme

        applyAttributes(to: textView, theme: theme)
        if textChanged {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTheme: RXTheme?
    }

    private func applyAttributes(to textView: NSTextView, theme: RXTheme) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(theme.text),
            .paragraphStyle: paragraphStyle,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        textView.textStorage?.setAttributedString(attributed)
    }
}
