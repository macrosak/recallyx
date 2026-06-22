import SwiftUI
import RecallyxCore

/// Popover content: scrollable grid of curated SF Symbols. Tapping a symbol
/// updates the binding and dismisses. Copied from AI Replace.
struct IconPickerView: View {
    @Binding var selection: String
    let onPick: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 7)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(IconCatalog.curated, id: \.self) { name in
                    Button {
                        selection = name
                        onPick()
                    } label: {
                        Image(systemName: name)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(name == selection ? Color.accentColor.opacity(0.3) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            .padding(8)
        }
        .frame(width: 300, height: 220)
    }
}
