import Foundation

/// Curated SF Symbol names exposed in the action icon picker. Copied from AI
/// Replace and widened a little for script/AI/clipboard actions.
enum IconCatalog {
    static let curated: [String] = [
        // AI / magic
        "sparkles", "sparkle", "wand.and.stars", "wand.and.rays", "brain", "lightbulb", "bolt",
        // Script / code
        "scroll", "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right", "function", "hammer",
        // Text / grammar
        "textformat", "textformat.abc", "textformat.abc.dottedunderline", "text.cursor",
        "text.alignleft", "text.badge.checkmark", "text.bubble", "character.bubble", "abc",
        // Edit / write
        "pencil", "pencil.tip", "highlighter", "scissors", "doc.text", "square.and.pencil",
        // Languages / world
        "globe", "globe.americas", "globe.europe.africa", "character.book.closed",
        // Status / quality
        "checkmark.seal", "checkmark.circle", "checkmark.bubble", "exclamationmark.bubble",
        // Workflow
        "arrow.triangle.2.circlepath", "arrow.right.square", "paperplane", "tray.and.arrow.down",
        // Misc
        "star", "tag", "gear",
    ]

    static let fallback = "sparkles"
}
