import Foundation

/// Pure text formatting for the `recallyx` CLI list output. No I/O — every
/// helper is a plain function of its inputs so the row layout, snippet
/// truncation, and index padding are unit-testable.
public enum CLIFormat {
    /// Default single-line snippet width for list rows.
    public static let snippetWidth = 100

    /// Collapse a clip's preview/text to a single line, trimmed and truncated to
    /// `width` characters (an ellipsis replaces the tail when longer). Newlines
    /// and runs of whitespace collapse to single spaces so a multi-line clip
    /// stays on one row.
    public static func snippet(_ raw: String, width: Int = snippetWidth) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > width else { return trimmed }
        // Reserve one char for the ellipsis.
        let end = trimmed.index(trimmed.startIndex, offsetBy: max(0, width - 1))
        return String(trimmed[trimmed.startIndex..<end]) + "…"
    }

    /// The single-line description of a clip for `search` / `recent`:
    /// `  3  text   5 min ago   Safari   the snippet…`
    /// - index is 1-based and right-padded to `indexWidth` for column alignment.
    /// - kind is `text` / `image`.
    /// - image clips with no OCR text show their dimensions as the snippet.
    public static func row(
        index: Int,
        item: HistoryItem,
        now: Date = Date(),
        indexWidth: Int = 2,
        snippetWidth: Int = snippetWidth
    ) -> String {
        let idx = String(index).leftPadded(to: indexWidth)
        let kind = item.kind.rawValue.rightPadded(to: 5)
        let time = ClipTime.relative(item.recency, now: now).rightPadded(to: 10)
        let app = (item.sourceAppName ?? "—").rightPadded(to: 14)
        let body = snippet(bodyText(for: item), width: snippetWidth)
        return "\(idx)  \(kind)  \(time)  \(app)  \(body)"
    }

    /// The text used as a row's snippet: inline text, or the OCR transcript for
    /// an image clip, else the preview (which for images is "Image · WxH").
    public static func bodyText(for item: HistoryItem) -> String {
        if let t = item.text, !t.isEmpty { return t }
        if let ocr = item.ocrText, !ocr.isEmpty { return ocr }
        return item.preview
    }

    /// A `list-actions` line: name padded to `width`, then the SCRIPT/AI tag.
    public static func actionLine(name: String, kindTag: String, width: Int) -> String {
        "\(name.rightPadded(to: width))  \(kindTag)"
    }
}

extension String {
    /// Right-pad with spaces to at least `width` (never truncates).
    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }

    /// Left-pad with spaces to at least `width` (never truncates).
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
