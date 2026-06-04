import SwiftUI

/// A keycap, mirroring the proposal's `Kbd`.
struct Keycap: View {
    let label: String
    let theme: RXTheme

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.text)
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.chip)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.chipBorder, lineWidth: 0.5))
            )
    }
}

struct HintItem: Identifiable {
    let id = UUID()
    let keys: [String]
    let label: String
}

/// Footer hint bar, right-aligned keycap + label pairs, with an optional left note.
struct HintBar: View {
    let items: [HintItem]
    let theme: RXTheme
    var left: String? = nil

    var body: some View {
        HStack(spacing: 18) {
            if let left {
                Text(left)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textFaint)
            }
            Spacer(minLength: 0)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    ForEach(Array(item.keys.enumerated()), id: \.offset) { _, k in
                        Keycap(label: k, theme: theme)
                    }
                    Text(item.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }
}

/// Uppercase column header, mirroring the proposal's `ColHead`.
struct ColumnHeader<Trailing: View>: View {
    let label: String
    let theme: RXTheme
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(theme.textDim)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }
}

extension ColumnHeader where Trailing == EmptyView {
    init(label: String, theme: RXTheme) {
        self.init(label: label, theme: theme, trailing: { EmptyView() })
    }
}
