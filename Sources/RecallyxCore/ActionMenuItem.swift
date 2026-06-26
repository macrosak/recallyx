import Foundation

/// Built-in item actions surfaced in the Tab action menu. (User-defined
/// script/AI actions and the Custom… one-off are layered on in Phase 2.)
public enum BuiltinAction: String, Identifiable, CaseIterable {
    case paste
    /// Paste the clip out line by line (a single-line ⌘V per line + a real ⌥Return
    /// between lines) instead of one multi-line clipboard paste — dodges terminals'
    /// bracketed-paste collapse (Claude Code's `[Pasted text]`). Text clips only.
    case pasteAsLines
    case copy
    case pin
    case unpin
    case delete
    case copyFilePath
    case revealInFinder
    case openInPreview

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .paste: return "Paste"
        case .pasteAsLines: return "Paste as lines"
        case .copy: return "Copy"
        case .pin: return "Pin"
        case .unpin: return "Unpin"
        case .delete: return "Delete from history"
        case .copyFilePath: return "Copy file path"
        case .revealInFinder: return "Reveal in Finder"
        case .openInPreview: return "Open in Preview"
        }
    }

    public var subtitle: String? {
        switch self {
        case .copy: return "without pasting"
        case .pasteAsLines: return "pastes it line by line"
        default: return nil
        }
    }

    public var icon: String {
        switch self {
        case .paste: return "doc.on.clipboard"
        case .pasteAsLines: return "text.alignleft"
        case .copy: return "doc.on.doc"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .delete: return "trash"
        case .copyFilePath: return "link"
        case .revealInFinder: return "folder"
        case .openInPreview: return "eye"
        }
    }

    public var isDanger: Bool { self == .delete }

    /// The built-ins available for a given clip kind, in display order.
    /// "Paste as lines" is text-only — pasting image bytes line-by-line makes no sense.
    public static func entries(for kind: ClipKind) -> [BuiltinAction] {
        switch kind {
        case .text: return [.paste, .pasteAsLines, .copy, .delete]
        case .image: return [.paste, .openInPreview, .copyFilePath, .revealInFinder, .delete]
        }
    }
}

/// One row in the action menu: a built-in, a saved user action, or the Custom…
/// one-off entry. Indexed positionally by the view model's cursor.
public enum ActionMenuItem: Identifiable {
    case builtin(BuiltinAction)
    case custom
    case saved(Action)

    public var id: String {
        switch self {
        case .builtin(let b): return "builtin.\(b.rawValue)"
        case .custom: return "custom"
        case .saved(let a): return "saved.\(a.id.uuidString)"
        }
    }

    /// Text the action search matches against.
    public var searchText: String {
        switch self {
        case .builtin(let b): return b.title
        case .custom: return "Custom"
        case .saved(let a): return a.name
        }
    }
}
