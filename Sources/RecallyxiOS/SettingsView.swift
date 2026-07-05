import RecallyxCore
import SwiftUI

/// Minimal iOS settings sheet. The MVP needs exactly one control: the iCloud
/// sync toggle. It's stored in `@AppStorage("iCloudSyncEnabled")` (default on —
/// the synced clips are the app's entire value) and read once at launch by
/// `RecallyxApp` when it builds the store, so a change takes effect on relaunch.
/// Below it, a "Last sync" line mirrors the Mac's status (the same shared
/// `SyncActivityMonitor` / `SyncStatusLine`).
struct SettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @ObservedObject var syncMonitor: SyncActivityMonitor
    @Environment(\.dismiss) private var dismiss

    private var syncStatusLine: String? {
        SyncStatusLine.text(
            lastExport: syncMonitor.lastExportSuccess,
            lastImport: syncMonitor.lastImportSuccess,
            lastError: syncMonitor.lastError
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("iCloud sync", isOn: $iCloudSyncEnabled)
                    if iCloudSyncEnabled {
                        LabeledContent("Last sync", value: syncStatusLine ?? "Waiting…")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Your clipboard history syncs through your private iCloud (CloudKit private database) across your devices. Changing this takes effect the next time you open the app. Pull down on the list to sync now.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
