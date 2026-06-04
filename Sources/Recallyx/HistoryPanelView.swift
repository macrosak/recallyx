import SwiftUI

/// The ⌘⇧V panel content: search bar on top, list + detail below, hint bar
/// footer — laid out to match the proposal's `HistoryPanel`.
struct HistoryPanelView: View {
    @ObservedObject var viewModel: HistoryPanelViewModel
    /// Resolves an image item to its on-disk PNG (the store owns the path).
    let imageURL: (HistoryItem) -> URL?
    /// Default model name shown in the Custom… footer.
    var defaultModel: String = ModelCatalog.default

    /// Which control holds keyboard focus. Search in list mode; the ad-hoc AI
    /// editor in custom/edit mode; nothing in the action menu (so typed letters
    /// don't mutate the search query under it).
    enum Field: Hashable { case search, editor }

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: Field?

    private var theme: RXTheme { RXTheme.current(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if viewModel.isEmpty {
                EmptyHistoryView(theme: theme)
                    .frame(height: 470)
            } else {
                HStack(spacing: 0) {
                    leftColumn
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(theme.hairline).frame(width: 0.5)
                        }
                    rightColumn
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 470)
            }
            HintBar(items: hints, theme: theme)
        }
        .frame(width: 760)
        .background(theme.panelTint)
        .onAppear { focus = .search }
        .onChange(of: viewModel.mode) { syncFocus($0) }
    }

    /// Move focus to the right control as the mode changes (see `Field`).
    private func syncFocus(_ mode: HistoryPanelViewModel.Mode) {
        switch mode {
        case .list: focus = .search
        case .actions: focus = nil
        case .custom, .edit: focus = .editor
        }
    }

    private var hints: [HintItem] {
        switch viewModel.mode {
        case .list:
            return [
                HintItem(keys: ["↵"], label: "Paste"),
                HintItem(keys: ["⇥"], label: "Actions"),
                HintItem(keys: ["esc"], label: "Close"),
            ]
        case .actions:
            return [
                HintItem(keys: ["↑", "↓"], label: "select"),
                HintItem(keys: ["↵"], label: "run"),
                HintItem(keys: ["⇥"], label: "edit"),
                HintItem(keys: ["esc"], label: "back"),
            ]
        case .custom:
            return [
                HintItem(keys: ["↵"], label: "run once"),
                HintItem(keys: ["esc"], label: "back"),
            ]
        case .edit:
            return [
                HintItem(keys: ["⇥"], label: "next step"),
                HintItem(keys: ["⌘", "↵"], label: "run"),
                HintItem(keys: ["esc"], label: "cancel"),
            ]
        }
    }

    // MARK: - Columns (swap by mode)

    @ViewBuilder
    private var leftColumn: some View {
        switch viewModel.mode {
        case .list: list
        // The clip you're acting on becomes the context column.
        case .actions, .custom, .edit: detail(viewModel.actionItem)
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        switch viewModel.mode {
        case .list:
            detail(viewModel.selectedItem)
        case .actions:
            if let item = viewModel.actionItem {
                ActionMenuColumn(
                    item: item,
                    items: viewModel.menuItems,
                    selectedIndex: viewModel.actionIndex,
                    theme: theme,
                    onTap: { idx in
                        viewModel.actionIndex = idx
                        viewModel.confirm()
                    }
                )
            } else {
                Color.clear
            }
        case .custom:
            if let item = viewModel.actionItem {
                CustomPromptColumn(item: item, text: $viewModel.customText, defaultModel: defaultModel, theme: theme, focus: $focus)
            } else {
                Color.clear
            }
        case .edit:
            if let action = viewModel.editAction {
                EditStepsColumn(action: action, stepIndex: viewModel.editStepIndex, body_: $viewModel.editBody, theme: theme, focus: $focus)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.textDim)
            TextField("Search clipboard…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(theme.text)
                .focused($focus, equals: .search)
            Text("\(viewModel.filtered.count) clips")
                .font(.system(size: 12))
                .foregroundStyle(theme.textFaint)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(viewModel.filtered.enumerated()), id: \.element.id) { idx, item in
                        HistoryRowView(item: item, active: idx == viewModel.selectedIndex, theme: theme)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedIndex = idx
                                viewModel.confirm()
                            }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(theme.rail)
            .onChange(of: viewModel.selectedIndex) { _ in
                if let id = viewModel.selectedItem?.id {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ item: HistoryItem?) -> some View {
        if let item {
            DetailPaneView(item: item, theme: theme, imageURL: imageURL(item))
        } else {
            Color.clear
        }
    }
}

/// One history list row — app icon, snippet (2 lines text / 1 line + dims image),
/// relative time. Selected rows get the vivid blue fill + white text.
struct HistoryRowView: View {
    let item: HistoryItem
    let active: Bool
    let theme: RXTheme

    private var fg: Color { active ? .white : theme.text }
    private var faint: Color { active ? .white.opacity(0.62) : theme.textFaint }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            AppIconView(item: item, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(item.isMono ? .system(size: 13.5, design: .monospaced) : .system(size: 13.5))
                    .foregroundStyle(fg)
                    .lineLimit(item.kind == .image ? 1 : 2)
                    .multilineTextAlignment(.leading)
                if item.kind == .image, let dims = item.imageDimensions {
                    Text(dims)
                        .font(.system(size: 11.5))
                        .foregroundStyle(faint)
                }
            }
            Spacer(minLength: 6)
            Text(ClipTime.relative(item.recency))
                .font(.system(size: 11.5))
                .foregroundStyle(faint)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? theme.sel : .clear)
                .shadow(color: active ? Color(rgba: 10, 90, 200, 0.35) : .clear, radius: 3, y: 1)
        )
        .padding(.horizontal, 8)
    }
}

/// Right detail pane — full text (mono, scrollable) or image preview, plus a
/// provenance footer.
struct DetailPaneView: View {
    let item: HistoryItem
    let theme: RXTheme
    let imageURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .image {
            VStack(alignment: .leading, spacing: 10) {
                imagePreview
                Text(item.preview)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                if let dims = item.imageDimensions {
                    Text("\(dims) · PNG · \(byteString)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textFaint)
                }
            }
        } else {
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let imageURL, let nsImage = NSImage(contentsOf: imageURL) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 200, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.chip)
                .frame(height: 184)
                .overlay(Text("missing image").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textFaint))
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            AppIconView(item: item, size: 16)
            HStack(spacing: 4) {
                Text("Copied from")
                Text(item.sourceAppName ?? "Unknown")
                    .foregroundStyle(theme.text)
                    .fontWeight(.medium)
            }
            Text("·").foregroundStyle(theme.textFaint)
            Text(ClipTime.clock(item.createdAt)).monospacedDigit()
            Spacer()
            Text(byteString)
                .foregroundStyle(theme.textFaint)
                .monospacedDigit()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(theme.textDim)
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private var byteString: String { ByteFormat.string(item.byteSize) }
}

/// Empty / first-run state, mirroring the proposal's empty panel.
struct EmptyHistoryView: View {
    let theme: RXTheme

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            BrandMark(size: 56, color: theme.accent)
            Text("Your clipboard history lives here")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Copy anything — text or images — and it appears at the top, ready to search and paste.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

extension HistoryItem {
    /// Code/shell-ish clips render monospaced in the list snippet.
    var isMono: Bool {
        guard kind == .text, let text else { return false }
        return text.contains("{") || text.contains(";") || text.contains("func ") || text.hasPrefix("$")
    }
}

enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
