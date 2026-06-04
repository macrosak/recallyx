import SwiftUI

extension Color {
    /// 0–255 channels + 0–1 alpha, matching the design tokens' rgba() values.
    init(rgba r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    /// `#rrggbb`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Design tokens from the Recallyx proposal (`screens/system.jsx` → `RX`),
/// translated to SwiftUI `Color`. Two instances — `.dark` / `.light` — selected
/// by the environment color scheme. The frosted panel background comes from an
/// `NSVisualEffectView`; these tokens drive everything drawn on top.
struct RXTheme {
    let text: Color
    let textDim: Color
    let textFaint: Color
    let hairline: Color
    let accent: Color
    /// Selected-row fill (vivid blue).
    let sel: Color
    let selSoft: Color
    let rail: Color
    let chip: Color
    let chipBorder: Color
    let field: Color
    let fieldBorder: Color
    let good: Color
    let warn: Color
    let bad: Color
    /// Thin tint laid over the vibrancy blur to nudge it toward the mock.
    let panelTint: Color

    var isDark: Bool

    static func current(_ scheme: ColorScheme) -> RXTheme {
        scheme == .dark ? .dark : .light
    }

    static let dark = RXTheme(
        text: Color(white: 1, opacity: 0.92),
        textDim: Color(white: 1, opacity: 0.56),
        textFaint: Color(white: 1, opacity: 0.34),
        hairline: Color(white: 1, opacity: 0.09),
        accent: Color(hex: 0x0A84FF),
        sel: Color(rgba: 10, 132, 255, 0.92),
        selSoft: Color(rgba: 10, 132, 255, 0.16),
        rail: Color(white: 1, opacity: 0.03),
        chip: Color(white: 1, opacity: 0.08),
        chipBorder: Color(white: 1, opacity: 0.14),
        field: Color(white: 1, opacity: 0.07),
        fieldBorder: Color(white: 1, opacity: 0.10),
        good: Color(hex: 0x30D158),
        warn: Color(hex: 0xFF9F0A),
        bad: Color(hex: 0xFF453A),
        panelTint: Color(rgba: 34, 34, 38, 0.40),
        isDark: true
    )

    static let light = RXTheme(
        text: Color(white: 0, opacity: 0.86),
        textDim: Color(white: 0, opacity: 0.50),
        textFaint: Color(white: 0, opacity: 0.32),
        hairline: Color(white: 0, opacity: 0.09),
        accent: Color(hex: 0x007AFF),
        sel: Color(rgba: 0, 122, 255, 0.96),
        selSoft: Color(rgba: 0, 122, 255, 0.12),
        rail: Color(white: 0, opacity: 0.018),
        chip: Color(white: 0, opacity: 0.05),
        chipBorder: Color(white: 0, opacity: 0.12),
        field: Color(white: 0, opacity: 0.045),
        fieldBorder: Color(white: 0, opacity: 0.10),
        good: Color(hex: 0x28B350),
        warn: Color(hex: 0xD98300),
        bad: Color(hex: 0xE0352B),
        panelTint: Color(rgba: 247, 247, 249, 0.45),
        isDark: false
    )
}

/// Brand mark — two offset rounded rects (a clip stacked on a clip), matching
/// `Mark` in the proposal. Used in the empty state and Settings.
struct BrandMark: View {
    var size: CGFloat = 18
    var color: Color = Color(hex: 0x0A84FF)

    var body: some View {
        Canvas { ctx, sizeRect in
            let s = sizeRect.width
            func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x / 24 * s, y: y / 24 * s, width: w / 24 * s, height: w / 24 * s),
                     cornerRadius: 3.2 / 24 * s)
            }
            let back = rrect(7.5, 3.5, 13)
            ctx.stroke(back, with: .color(color.opacity(0.5)), lineWidth: 1.7 / 24 * s)
            let front = rrect(3.5, 7.5, 13)
            ctx.fill(front, with: .color(color.opacity(0.16)))
            ctx.stroke(front, with: .color(color), lineWidth: 1.7 / 24 * s)
        }
        .frame(width: size, height: size)
    }
}

/// Source-app icon for a clip, or a generic placeholder when the app can't be
/// resolved (uninstalled / programmatic write).
struct AppIconView: View {
    let item: HistoryItem
    var size: CGFloat = 20

    var body: some View {
        if let icon = AppIconProvider.shared.icon(for: item) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(Color.gray.opacity(0.4))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: item.kind == .image ? "photo" : "doc.on.clipboard")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.white.opacity(0.8))
                )
        }
    }
}
