import SwiftUI

/// Built-in item actions surfaced in the Tab action menu. (User-defined
/// script/AI actions and the Custom… one-off are layered on in Phase 2.)
enum BuiltinAction: String, Identifiable, CaseIterable {
    case paste
    case copy
    case delete
    case copyFilePath
    case revealInFinder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "Paste"
        case .copy: return "Copy"
        case .delete: return "Delete from history"
        case .copyFilePath: return "Copy file path"
        case .revealInFinder: return "Reveal in Finder"
        }
    }

    var subtitle: String? {
        switch self {
        case .copy: return "without pasting"
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .paste: return "doc.on.clipboard"
        case .copy: return "doc.on.doc"
        case .delete: return "trash"
        case .copyFilePath: return "link"
        case .revealInFinder: return "folder"
        }
    }

    var isDanger: Bool { self == .delete }

    /// The built-ins available for a given clip kind, in display order.
    static func entries(for kind: ClipKind) -> [BuiltinAction] {
        switch kind {
        case .text: return [.paste, .copy, .delete]
        case .image: return [.paste, .copyFilePath, .revealInFinder, .delete]
        }
    }
}

/// The right column when the action menu is open: an "ACTIONS" header (with the
/// clip's app icon) over the list of built-in action rows.
struct ActionMenuColumn: View {
    let item: HistoryItem
    let entries: [BuiltinAction]
    let selectedIndex: Int
    let theme: RXTheme
    let onTap: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(label: "Actions", theme: theme) {
                AppIconView(item: item, size: 15)
            }
            VStack(spacing: 1) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, action in
                    ActionRowView(
                        icon: action.icon,
                        title: action.title,
                        subtitle: action.subtitle,
                        tag: nil,
                        danger: action.isDanger,
                        active: idx == selectedIndex,
                        theme: theme
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(idx) }
                }
            }
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
    }
}

/// One row in the action menu — icon · name (+ optional subtitle) · optional
/// SCRIPT/AI tag. Matches the proposal's `ActionRow`.
struct ActionRowView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let tag: String?
    let danger: Bool
    let active: Bool
    let theme: RXTheme

    private var fg: Color { active ? .white : (danger ? theme.bad : theme.text) }
    private var iconColor: Color { active ? .white : (danger ? theme.bad : theme.textDim) }
    private var subColor: Color { active ? .white.opacity(0.7) : theme.textFaint }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(fg)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(subColor)
                }
            }
            Spacer(minLength: 6)
            if let tag {
                Text(tag.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(active ? .white.opacity(0.85) : theme.textFaint)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(active ? theme.sel : .clear)
        )
        .padding(.horizontal, 6)
    }
}
