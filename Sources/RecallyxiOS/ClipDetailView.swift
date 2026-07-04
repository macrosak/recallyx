import RecallyxCore
import SwiftUI
import UIKit

/// Full-clip detail: scrollable text, a provenance footer, and a prominent Copy
/// button that writes the iOS pasteboard with success haptics + a transient
/// toast. Image clips show a "not synced to this device" placeholder (image
/// payloads don't sync yet).
struct ClipDetailView: View {
    let item: HistoryItem

    @State private var showCopiedToast = false
    @State private var copyTrigger = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            if showCopiedToast { copiedToast }
        }
        .navigationTitle(item.kind == .image ? "Image" : "Clip")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: copyTrigger)
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .image {
            imagePlaceholder
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    Text(item.text ?? item.preview)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                footer
                copyButton
                    .padding()
            }
        }
    }

    private var imagePlaceholder: some View {
        VStack(spacing: 0) {
            ContentUnavailableView(
                ClipListDisplay.imagePlaceholderTitle(for: item),
                systemImage: "photo",
                description: Text("Image — not synced to this device.")
            )
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
            Text(item.sourceAppName ?? "Unknown app")
            Spacer()
            Text("\(ClipTime.relative(item.recency)) · \(ClipTime.clock(item.createdAt))")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var copiedToast: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 88)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func copy() {
        guard let text = item.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copyTrigger += 1
        withAnimation(.spring(duration: 0.25)) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.25)) { showCopiedToast = false }
        }
    }
}
