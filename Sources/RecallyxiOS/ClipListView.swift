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
                ToolbarItem(placement: .bottomBar) {
                    // The app's only capture affordance: a prominent, labelled
                    // capsule ("Paste") centered in the bottom bar. Tapping it
                    // pastes the clipboard into history **without** iOS's
                    // clipboard-access alert (that's why it's a `UIPasteControl`,
                    // not a plain Button). It dims — but stays visible — when the
                    // pasteboard has no text. The explicit frame is load-bearing:
                    // without it the wrapped `UIView` reports no intrinsic size and
                    // the button collapses to nothing (the original bug).
                    // NOTE: `UIPasteControl` content is redacted from Simulator
                    // screen captures for security, so it looks blank in
                    // screenshots but renders fully on device.
                    PasteCaptureControl(onPasteText: capture)
                        .frame(width: 230, height: 44)
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
                SettingsView(syncMonitor: sync.activity)
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
        .refreshable { await refresh() }
    }

    /// Pull-to-refresh: kick a fresh CloudKit pull and hold the spinner until the
    /// import completes (or times out), then surface the downloaded rows. Instant
    /// no-op when sync is off / unentitled — the store's kick and the wait both
    /// short-circuit — so the gesture never hangs. NSPersistentCloudKitContainer
    /// has no fetch-now API, so this triggers an import via a store reload and
    /// waits for it; if nothing is pending on the server the wait times out.
    private func refresh() async {
        guard store.isCloudSyncActive else { return }
        store.refreshFromCloud()
        await sync.awaitNextImport()
        store.refreshItemsFromStore()
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
        guard let clip = CapturedClip.forText(
            text,
            sourceAppName: "iPhone",
            sourceDeviceName: UIDevice.current.name,
            sourceDeviceType: "iphone"
        ) else { return }
        store.add(clip)
        copyTrigger += 1
    }
}

/// One clip row: snippet (or "Image · WxH" placeholder for image clips), then a
/// secondary line with source-app name + relative time.
private struct ClipRow: View {
    let item: HistoryItem

    /// Non-nil when this clip was captured on a different device than this
    /// iPhone (see `ClipOrigin.originBadge`) — a clip synced in from the Mac,
    /// or from a different iPhone. Nil for a clip captured here, or one with
    /// no recorded origin (pre-feature clips).
    private var originBadge: OriginBadgeKind? {
        ClipOrigin.originBadge(for: item, currentDeviceName: UIDevice.current.name)
    }

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
                    if let originBadge {
                        Image(systemName: originBadge.systemImageName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
