import SwiftUI

/// The Actions settings tab: a list of actions on the left, the selected
/// action's step-pipeline editor on the right. Matches the proposal's
/// `SettingsActions`.
struct SettingsActionsView: View {
    @ObservedObject var settingsStore: SettingsStore
    let theme: SettingsTheme

    @State private var selectedID: UUID?
    @State private var iconPickerOpen = false

    private var actions: [Action] { settingsStore.settings.actions }

    var body: some View {
        HStack(spacing: 0) {
            actionList
                .frame(width: 224)
                .overlay(alignment: .trailing) { Rectangle().fill(theme.cardBorder).frame(width: 0.5) }
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 460)
        .onAppear { if selectedID == nil { selectedID = actions.first?.id } }
    }

    // MARK: - Action list (left)

    private var actionList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                        actionRow(action, idx: idx)
                    }
                }
                .padding(8)
            }
            HStack(spacing: 2) {
                toolbarButton("plus") { addAction() }
                toolbarButton("minus") { deleteSelected() }
                Spacer()
                toolbarButton("arrow.clockwise") { restoreBuiltins() }
                    .help("Restore built-in actions")
            }
            .padding(8)
            .overlay(alignment: .top) { Rectangle().fill(theme.cardBorder).frame(height: 0.5) }
        }
        .background(theme.isDark ? Color(white: 0, opacity: 0.12) : Color(white: 0, opacity: 0.02))
    }

    private func actionRow(_ action: Action, idx: Int) -> some View {
        let on = action.id == selectedID
        return HStack(spacing: 9) {
            Image(systemName: action.icon)
                .font(.system(size: 14))
                .foregroundStyle(on ? .white : theme.textDim)
                .frame(width: 18)
            Text(action.name)
                .font(.system(size: 13))
                .foregroundStyle(on ? .white : theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if on && actions.count > 1 {
                actionReorder(idx: idx)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.accent : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = action.id }
    }

    private func actionReorder(idx: Int) -> some View {
        let canMoveUp = idx > 0
        let canMoveDown = idx < actions.count - 1
        return HStack(spacing: 1) {
            Button { moveAction(from: idx, to: idx - 1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain).disabled(!canMoveUp)
            .foregroundStyle(canMoveUp ? Color.white : Color.white.opacity(0.35))
            Button { moveAction(from: idx, to: idx + 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain).disabled(!canMoveDown)
            .foregroundStyle(canMoveDown ? Color.white : Color.white.opacity(0.35))
        }
    }

    private func toolbarButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textDim)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editor (right)

    @ViewBuilder
    private var editor: some View {
        if let binding = selectedActionBinding {
            VStack(alignment: .leading, spacing: 14) {
                header(binding)
                stepsSection(binding)
                Text("Text flows through enabled steps in order — disabled steps are skipped, a failing step aborts before pasting. Text-only in v1.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textFaint)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        } else {
            VStack {
                Spacer()
                Text("No actions yet — add one with +.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textDim)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ action: Binding<Action>) -> some View {
        HStack(spacing: 12) {
            Button { iconPickerOpen = true } label: {
                Image(systemName: action.wrappedValue.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(theme.segBg))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $iconPickerOpen) {
                IconPickerView(selection: action.icon) { iconPickerOpen = false }
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Action name", theme: theme)
                SettingsField(text: action.name, placeholder: "Name", width: nil, theme: theme)
            }
        }
    }

    private func stepsSection(_ action: Binding<Action>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel(text: "Steps · runs top to bottom", theme: theme)
                Spacer()
                SettingsButton(title: "+ Add step", theme: theme) { addStep(to: action) }
            }
            VStack(spacing: 10) {
                ForEach(Array(action.wrappedValue.steps.enumerated()), id: \.element.id) { idx, _ in
                    StepCard(
                        step: action.steps[idx],
                        theme: theme,
                        canMoveUp: idx > 0,
                        canMoveDown: idx < action.wrappedValue.steps.count - 1,
                        onMoveUp: { move(action, from: idx, to: idx - 1) },
                        onMoveDown: { move(action, from: idx, to: idx + 1) },
                        onDelete: { action.wrappedValue.steps.remove(at: idx) }
                    )
                }
            }
        }
    }

    // MARK: - Mutations

    private var selectedActionBinding: Binding<Action>? {
        guard let id = selectedID, settingsStore.settings.actions.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { settingsStore.settings.actions.first { $0.id == id } ?? Action(name: "", icon: "sparkles", steps: []) },
            set: { newValue in
                if let i = settingsStore.settings.actions.firstIndex(where: { $0.id == id }) {
                    settingsStore.settings.actions[i] = newValue
                }
            }
        )
    }

    private func addAction() {
        let action = Action(name: "New action", icon: "sparkles", steps: [Step(type: .ai)])
        settingsStore.settings.actions.append(action)
        selectedID = action.id
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        settingsStore.settings.actions.removeAll { $0.id == id }
        selectedID = settingsStore.settings.actions.first?.id
    }

    /// Append any shipped built-in actions the user is missing (append-only,
    /// idempotent, matched by name). How existing installs pick up newly added
    /// defaults, and a way to recover a default deleted by accident.
    private func restoreBuiltins() {
        let before = settingsStore.settings.actions
        let merged = Action.appendingMissingBuiltins(into: before)
        guard merged.count != before.count else { return }
        settingsStore.settings.actions = merged
        if selectedID == nil { selectedID = merged.first?.id }
    }

    private func moveAction(from: Int, to: Int) {
        var list = settingsStore.settings.actions
        guard list.indices.contains(from), list.indices.contains(to) else { return }
        let action = list.remove(at: from)
        list.insert(action, at: to)
        settingsStore.settings.actions = list
    }

    private func addStep(to action: Binding<Action>) {
        action.wrappedValue.steps.append(Step(type: .script))
    }

    private func move(_ action: Binding<Action>, from: Int, to: Int) {
        guard action.wrappedValue.steps.indices.contains(from),
              action.wrappedValue.steps.indices.contains(to) else { return }
        let step = action.wrappedValue.steps.remove(at: from)
        action.wrappedValue.steps.insert(step, at: to)
    }
}

/// One step card in the editor: type segmented · enable · trash · reorder, then
/// the body (bash text for Script, prompt + model override for AI).
struct StepCard: View {
    @Binding var step: Step
    let theme: SettingsTheme
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
        }
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.cardBorder, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .opacity(step.enabled ? 1 : 0.55)
    }

    private var header: some View {
        HStack(spacing: 10) {
            typeSeg
            Spacer()
            reorder
            Text(step.enabled ? "On" : "Off").font(.system(size: 11.5)).foregroundStyle(theme.textDim)
            Toggle("", isOn: $step.enabled).toggleStyle(.switch).labelsHidden().tint(theme.accent).controlSize(.mini)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(theme.textFaint)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.rowSep).frame(height: 0.5) }
    }

    private var typeSeg: some View {
        HStack(spacing: 3) {
            seg("Script", "scroll", .script)
            seg("AI", "sparkle", .ai)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.segBg))
    }

    private func seg(_ label: String, _ icon: String, _ type: StepType) -> some View {
        let on = step.type == type
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(on ? theme.text : theme.textDim)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? (theme.isDark ? Color(white: 1, opacity: 0.12) : .white) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { step.type = type }
    }

    private var reorder: some View {
        HStack(spacing: 1) {
            Button(action: onMoveUp) { Image(systemName: "chevron.up").font(.system(size: 10)) }
                .buttonStyle(.plain).disabled(!canMoveUp).foregroundStyle(canMoveUp ? theme.textDim : theme.textFaint.opacity(0.4))
            Button(action: onMoveDown) { Image(systemName: "chevron.down").font(.system(size: 10)) }
                .buttonStyle(.plain).disabled(!canMoveDown).foregroundStyle(canMoveDown ? theme.textDim : theme.textFaint.opacity(0.4))
        }
    }

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: 8) {
            if step.type == .ai {
                StepBodyEditor(text: $step.prompt, theme: theme, placeholder: "Prompt — use {{TEXT}} for the clip")
                HStack(spacing: 8) {
                    Text("Model override").font(.system(size: 11.5)).foregroundStyle(theme.textDim)
                    Picker("", selection: Binding(
                        get: { step.model ?? "" },
                        set: { step.model = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Use default").tag("")
                        ForEach(ModelCatalog.groupsPreservingSelection(
                            ModelCatalog.availableGroups(),
                            selected: step.model ?? ""
                        )) { group in
                            Section(group.title) {
                                ForEach(group.models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    .labelsHidden().frame(width: 150)
                }
            } else {
                StepBodyEditor(text: $step.script, theme: theme, placeholder: "bash — stdin → stdout")
            }
        }
        .padding(10)
    }
}

/// Monospaced text editor for a step's body.
struct StepBodyEditor: View {
    @Binding var text: String
    let theme: SettingsTheme
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textFaint)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(minHeight: 54)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.inputBg)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.inputBorder, lineWidth: 0.5)))
    }
}
