import SwiftUI

/// Solid-window settings palette, translated from the proposal's `stheme`
/// (`settings.jsx`). Distinct from `RXTheme`, which is for the frosted panel.
struct SettingsTheme {
    let body: Color
    let chrome: Color
    let card: Color
    let cardBorder: Color
    let rowSep: Color
    let text: Color
    let textDim: Color
    let textFaint: Color
    let secLabel: Color
    let inputBg: Color
    let inputBorder: Color
    let segBg: Color
    let accent: Color
    let bad: Color
    let btn: Color
    let btnBorder: Color
    let isDark: Bool

    static func current(_ scheme: ColorScheme) -> SettingsTheme {
        scheme == .dark ? .dark : .light
    }

    static let dark = SettingsTheme(
        body: Color(hex: 0x1E1E20),
        chrome: Color(hex: 0x323234),
        card: Color(hex: 0x2C2C2E),
        cardBorder: Color(white: 1, opacity: 0.07),
        rowSep: Color(white: 1, opacity: 0.07),
        text: Color(white: 1, opacity: 0.92),
        textDim: Color(white: 1, opacity: 0.56),
        textFaint: Color(white: 1, opacity: 0.34),
        secLabel: Color(white: 1, opacity: 0.45),
        inputBg: Color(hex: 0x1C1C1E),
        inputBorder: Color(white: 1, opacity: 0.12),
        segBg: Color(white: 1, opacity: 0.08),
        accent: Color(hex: 0x0A84FF),
        bad: Color(hex: 0xFF453A),
        btn: Color(white: 1, opacity: 0.10),
        btnBorder: Color(white: 1, opacity: 0.12),
        isDark: true
    )

    static let light = SettingsTheme(
        body: Color(hex: 0xECECED),
        chrome: Color(hex: 0xF6F6F7),
        card: Color(hex: 0xFFFFFF),
        cardBorder: Color(white: 0, opacity: 0.07),
        rowSep: Color(white: 0, opacity: 0.07),
        text: Color(white: 0, opacity: 0.86),
        textDim: Color(white: 0, opacity: 0.50),
        textFaint: Color(white: 0, opacity: 0.32),
        secLabel: Color(white: 0, opacity: 0.45),
        inputBg: Color(hex: 0xFFFFFF),
        inputBorder: Color(white: 0, opacity: 0.14),
        segBg: Color(white: 0, opacity: 0.06),
        accent: Color(hex: 0x007AFF),
        bad: Color(hex: 0xE0352B),
        btn: Color(hex: 0xFFFFFF),
        btnBorder: Color(white: 0, opacity: 0.14),
        isDark: false
    )
}

/// Uppercase section label above a card.
struct SectionLabel: View {
    let text: String
    let theme: SettingsTheme

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(theme.secLabel)
            .padding(.leading, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded card wrapping a set of rows.
struct SettingsCard<Content: View>: View {
    let theme: SettingsTheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(theme.card)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// One settings row: label (+ optional description) on the left, controls right.
struct SettingsRow<Trailing: View>: View {
    let label: String
    var desc: String? = nil
    var last: Bool = false
    let theme: SettingsTheme
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(theme.text)
                if let desc {
                    Text(desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textDim)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(theme.rowSep).frame(height: 0.5) }
        }
    }
}

/// Pill button styles matching the proposal's `Btn`.
struct SettingsButton: View {
    enum Kind { case normal, primary, danger }
    let title: String
    var kind: Kind = .normal
    let theme: SettingsTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(fg)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(bg)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(border, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var fg: Color {
        switch kind {
        case .primary: return .white
        case .danger: return theme.bad
        case .normal: return theme.text
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: return theme.accent
        case .danger: return .clear
        case .normal: return theme.btn
        }
    }
    private var border: Color {
        switch kind {
        case .primary, .danger: return .clear
        case .normal: return theme.btnBorder
        }
    }
}

/// Styled text field used for the API key / retention cap inputs.
struct SettingsField: View {
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = false
    var width: CGFloat? = nil
    let theme: SettingsTheme

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.inputBg)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.inputBorder, lineWidth: 0.5))
            )
    }
}

/// Read-only shortcut keycaps row.
struct ShortcutChips: View {
    let keys: [String]
    let theme: SettingsTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(minWidth: 22, minHeight: 20)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(theme.segBg)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.btnBorder, lineWidth: 0.5))
                    )
            }
        }
    }
}
