import RecallyxCore
import SwiftUI
import UIKit

/// Root list: search + rows (snippet / image placeholder, source-app name,
/// relative time), pinned-first-then-recency. Tap a row → detail. Swipe leading
/// → Copy; swipe trailing → Pin/Unpin + Delete (all call the store, which syncs
/// back via CloudKit). Empty states cover first-sync-pending / no-results /
/// genuinely-empty.
struct ClipListView: View {
    @EnvironmentObject private var store: HistoryStore
    @StateObject private var vm: ClipListViewModel
    @StateObject private var sync = SyncStatusMonitor()

    @State private var settingsShown = false
    @State private var copyTrigger = 0

    init(store: HistoryStore) {
        _vm = StateObject(wrappedValue: ClipListViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.filtered.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Recallyx")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Paste the clipboard into history without triggering iOS's
                    // clipboard-access alert; the clip syncs to the Mac via CloudKit.
                    PasteCaptureControl(onPasteText: capture)
                        .fixedSize()
                        .accessibilityLabel("Paste from clipboard")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsShown = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .searchable(text: $vm.query, prompt: "Search clips")
            .sheet(isPresented: $settingsShown) {
                SettingsView()
            }
            .sensoryFeedback(.success, trigger: copyTrigger)
        }
    }

    private var list: some View {
        List(vm.filtered) { item in
            NavigationLink {
                ClipDetailView(item: item)
            } label: {
                ClipRow(item: item)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if item.kind == .text {
                    Button {
                        copy(item)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .tint(.green)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    store.delete(item.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    store.setPinned(item.id, !item.isPinned)
                } label: {
                    Label(item.isPinned ? "Unpin" : "Pin",
                          systemImage: item.isPinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if vm.isSearching {
            ContentUnavailableView.search(text: vm.query)
        } else if sync.isImporting && !sync.hasSyncedOnce {
            ContentUnavailableView {
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Downloading your clipboard history from iCloud.")
            }
        } else {
            ContentUnavailableView {
                Label("No clips yet", systemImage: "doc.on.clipboard")
            } description: {
                Text("Clips you copy on your Mac sync here through your private iCloud.")
            }
        }
    }

    private func copy(_ item: HistoryItem) {
        guard let text = item.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copyTrigger += 1
    }

    /// Add a pasted string to history as a text clip labeled "iPhone". The store
    /// dedupe-bumps identical content, persists it (dirty-set), and syncs it to
    /// the Mac via CloudKit; the list is bound to `store.$items` so the new clip
    /// surfaces at the top automatically. Non-text / empty pastes are dropped by
    /// the `HistoryItem.text` factory.
    private func capture(_ text: String) {
        guard let clip = CapturedClip.forText(text, sourceAppName: "iPhone") else { return }
        store.add(clip)
        copyTrigger += 1
    }
}

/// One clip row: snippet (or "Image · WxH" placeholder for image clips), then a
/// secondary line with source-app name + relative time.
private struct ClipRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 12) {
            if item.kind == .image {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(item.kind == .image ? .secondary : .primary)
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(ClipListDisplay.rowSubtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        item.kind == .image
            ? ClipListDisplay.imagePlaceholderTitle(for: item)
            : item.preview
    }
}
