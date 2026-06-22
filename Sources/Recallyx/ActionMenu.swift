import SwiftUI
import RecallyxCore

// `BuiltinAction` and `ActionMenuItem` are pure model types, moved to
// `RecallyxCore` (the view model depends on them); the SwiftUI views below stay
// in the macOS app target.

/// The right column when the action menu is open: an "ACTIONS" header (with the
/// clip's app icon) over built-in rows, then a "Saved actions" divider before
/// the user-defined actions.
struct ActionMenuColumn: View {
    let item: HistoryItem
    let items: [ActionMenuItem]
    let selectedIndex: Int
    /// While true, saved-action rows reveal a ⌘N quick-key badge (the same
    /// numbers `runSavedAction(at:)` honors). Built-ins/Custom… get none.
    var commandHeld: Bool = false
    let theme: RXTheme
    let onTap: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(label: "Actions", theme: theme) {
                AppIconView(item: item, size: 15)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                            if case .saved = entry, isFirstSaved(idx) {
                                MenuDivider(label: "Saved actions", theme: theme)
                            }
                            row(for: entry, at: idx, active: idx == selectedIndex)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(idx) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedIndex) { _ in
                    guard items.indices.contains(selectedIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selectedIndex, anchor: .center) }
                }
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
    private func row(for entry: ActionMenuItem, at idx: Int, active: Bool) -> some View {
        let quickKey = commandHeld ? HistoryPanelViewModel.actionQuickKey(forRowAt: idx, in: items) : nil
        switch entry {
        case .builtin(let b):
            ActionRowView(icon: b.icon, title: b.title, subtitle: b.subtitle, tag: nil,
                          danger: b.isDanger, active: active, quickKey: quickKey, theme: theme)
        case .custom:
            ActionRowView(icon: "sparkle", title: "Custom…", subtitle: "one-off prompt", tag: nil,
                          danger: false, active: active, quickKey: quickKey, theme: theme)
        case .saved(let a):
            ActionRowView(icon: a.icon, title: a.name, subtitle: nil, tag: a.kindTag,
                          danger: false, active: active, quickKey: quickKey, theme: theme)
        }
    }
}

/// Right column for the Custom… one-off prompt (a transient single-AI-step run).
struct CustomPromptColumn: View {
    let item: HistoryItem
    @Binding var text: String
    let defaultModel: String
    let theme: RXTheme
    var focus: FocusState<HistoryPanelView.Field?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(label: "Custom prompt", theme: theme) {
                AppIconView(item: item, size: 15)
            }
            VStack(alignment: .leading, spacing: 11) {
                Text("One-off instruction — runs once on this clip, then it's discarded.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textDim)
                PanelEditField(text: $text, theme: theme, minHeight: 92)
                    .focused(focus, equals: .editor)
                if item.kind == .image {
                    Text("The image is sent to the AI along with your instruction.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textFaint)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Text("{{TEXT}}")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.chip))
                        Text("is replaced with the clip. Omit it and the clip is appended to your instruction.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.textFaint)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(theme.textDim)
                    Text("Runs through the AI step · model \(defaultModel)")
                        .font(.system(size: 12)).foregroundStyle(theme.textDim)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
}

/// Right column for edit-before-run: paginated over a transient copy's steps.
struct EditStepsColumn: View {
    let action: Action
    let stepIndex: Int
    @Binding var body_: String
    let theme: RXTheme
    var focus: FocusState<HistoryPanelView.Field?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(label: "Edit & run · \(action.name)", theme: theme)
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    ForEach(Array(action.steps.enumerated()), id: \.element.id) { idx, step in
                        stepPill(idx: idx, step: step)
                    }
                    Spacer()
                    Text("Step \(stepIndex + 1) of \(action.steps.count)")
                        .font(.system(size: 11.5)).foregroundStyle(theme.textFaint).monospacedDigit()
                }
                Text(currentIsAI ? "PROMPT" : "BASH")
                    .font(.system(size: 11.5, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(theme.textFaint)
                PanelEditField(text: $body_, theme: theme, minHeight: 96)
                    .focused(focus, equals: .editor)
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(theme.textFaint)
                    Text("This run only — your saved “\(action.name)” is left untouched.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.textFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }

    private var currentIsAI: Bool {
        action.steps.indices.contains(stepIndex) && action.steps[stepIndex].type == .ai
    }

    private func stepPill(idx: Int, step: Step) -> some View {
        let on = idx == stepIndex
        return HStack(spacing: 6) {
            Text("\(idx + 1)").opacity(0.8)
            Image(systemName: step.type == .ai ? "sparkle" : "scroll").font(.system(size: 11))
            Text(step.type == .ai ? "AI" : "Script")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(on ? .white : theme.textDim)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.sel : theme.chip)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? .clear : theme.chipBorder, lineWidth: 0.5)))
    }
}

/// Accent-bordered monospaced editor used by the ad-hoc AI columns.
struct PanelEditField: View {
    @Binding var text: String
    let theme: RXTheme
    var minHeight: CGFloat = 92

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(theme.text)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.isDark ? Color(white: 0, opacity: 0.22) : Color(white: 0, opacity: 0.03))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.accent, lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.selSoft, lineWidth: 3).blur(radius: 1))
            )
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
    /// The ⌘-digit (1–9) to reveal in place of the trailing tag while ⌘ is held;
    /// nil shows the SCRIPT/AI tag (the default).
    var quickKey: Int? = nil
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
            if let quickKey {
                Keycap(label: "⌘\(quickKey)", theme: theme)
            } else if let tag {
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
