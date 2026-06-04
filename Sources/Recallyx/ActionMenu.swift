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

/// One row in the action menu: a built-in, a saved user action, or the Custom…
/// one-off entry. Indexed positionally by the view model's cursor.
enum ActionMenuItem: Identifiable {
    case builtin(BuiltinAction)
    case custom
    case saved(Action)

    var id: String {
        switch self {
        case .builtin(let b): return "builtin.\(b.rawValue)"
        case .custom: return "custom"
        case .saved(let a): return "saved.\(a.id.uuidString)"
        }
    }
}

/// The right column when the action menu is open: an "ACTIONS" header (with the
/// clip's app icon) over built-in rows, then a "Saved actions" divider before
/// the user-defined actions.
struct ActionMenuColumn: View {
    let item: HistoryItem
    let items: [ActionMenuItem]
    let selectedIndex: Int
    let theme: RXTheme
    let onTap: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(label: "Actions", theme: theme) {
                AppIconView(item: item, size: 15)
            }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                        if case .saved = entry, isFirstSaved(idx) {
                            MenuDivider(label: "Saved actions", theme: theme)
                        }
                        row(for: entry, active: idx == selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(idx) }
                    }
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private func isFirstSaved(_ idx: Int) -> Bool {
        guard idx > 0 else { return true }
        if case .saved = items[idx - 1] { return false }
        return true
    }

    @ViewBuilder
    private func row(for entry: ActionMenuItem, active: Bool) -> some View {
        switch entry {
        case .builtin(let b):
            ActionRowView(icon: b.icon, title: b.title, subtitle: b.subtitle, tag: nil,
                          danger: b.isDanger, active: active, theme: theme)
        case .custom:
            ActionRowView(icon: "sparkle", title: "Custom…", subtitle: "one-off prompt", tag: nil,
                          danger: false, active: active, theme: theme)
        case .saved(let a):
            ActionRowView(icon: a.icon, title: a.name, subtitle: nil, tag: a.kindTag,
                          danger: false, active: active, theme: theme)
        }
    }
}

/// Uppercase divider with a trailing hairline, mirroring the proposal's `Divider`.
struct MenuDivider: View {
    let label: String
    let theme: RXTheme

    var body: some View {
        HStack(spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textFaint)
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
