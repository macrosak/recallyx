import SwiftUI

enum SettingsTab: String, Hashable {
    case general
    case actions

    var title: String {
        switch self {
        case .general: return "General"
        case .actions: return "Actions"
        }
    }
}

/// Root of the Settings window: a custom header (segmented tabs + brand) over a
/// transparent native title bar (traffic lights show through), then the tab body.
/// Matches the proposal's `WinChrome`.
struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    let clearHistory: () -> Void
    let shortcutActions: ShortcutActions
    let revealUsageJournal: () -> Void
    let clearUsageJournal: () -> Void
    @State private var tab: SettingsTab

    private let tabs: [SettingsTab] = [.general, .actions]

    @Environment(\.colorScheme) private var colorScheme
    private var theme: SettingsTheme { SettingsTheme.current(colorScheme) }

    init(
        settingsStore: SettingsStore,
        clearHistory: @escaping () -> Void,
        shortcutActions: ShortcutActions,
        revealUsageJournal: @escaping () -> Void = {},
        clearUsageJournal: @escaping () -> Void = {},
        initialTab: SettingsTab = .general
    ) {
        self.settingsStore = settingsStore
        self.clearHistory = clearHistory
        self.shortcutActions = shortcutActions
        self.revealUsageJournal = revealUsageJournal
        self.clearUsageJournal = clearUsageJournal
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch tab {
            case .general:
                ScrollView {
                    SettingsGeneralView(settingsStore: settingsStore, clearHistory: clearHistory, shortcutActions: shortcutActions, revealUsageJournal: revealUsageJournal, clearUsageJournal: clearUsageJournal, theme: theme)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 20)
                }
            case .actions:
                SettingsActionsView(settingsStore: settingsStore, theme: theme)
            }
        }
        .background(theme.body)
        .frame(minWidth: 600, minHeight: 560)
        // Draw up under the transparent titlebar so the header band sits behind
        // the traffic lights (one unified bar), not below them. Without this,
        // NSHostingController insets the content by the titlebar height.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        ZStack {
            theme.chrome
            if tabs.count > 1 {
                SegmentedTabs(tabs: tabs, selection: $tab, theme: theme)
            }
            HStack {
                Spacer()
                HStack(spacing: 7) {
                    BrandMark(size: 16, color: theme.accent)
                    Text("Recallyx")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.cardBorder).frame(height: 0.5)
        }
    }
}

/// Pill segmented control in the title bar.
struct SegmentedTabs: View {
    let tabs: [SettingsTab]
    @Binding var selection: SettingsTab
    let theme: SettingsTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                let on = tab == selection
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? theme.text : theme.textDim)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            // Opaque pill: the header lives in the window's
                            // transparent titlebar, so a translucent white fill
                            // composites over the vibrant backdrop and reads too
                            // bright. A solid color matches the design's subtler
                            // active tab regardless of what's behind the window.
                            .fill(on ? (theme.isDark ? Color(hex: 0x47474B) : .white) : .clear)
                            .shadow(color: on && !theme.isDark ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = tab }
            }
        }
        .padding(3)
        // Opaque track for the same reason as the pill (transparent titlebar).
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.isDark ? Color(hex: 0x37373A) : theme.segBg))
    }
}
