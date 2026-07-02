import SwiftUI

/// Minimal iOS settings sheet. The MVP needs exactly one control: the iCloud
/// sync toggle. It's stored in `@AppStorage("iCloudSyncEnabled")` (default on —
/// the synced clips are the app's entire value) and read once at launch by
/// `RecallyxApp` when it builds the store, so a change takes effect on relaunch.
struct SettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("iCloud sync", isOn: $iCloudSyncEnabled)
                } footer: {
                    Text("Your clipboard history syncs through your private iCloud (CloudKit private database) across your devices. Changing this takes effect the next time you open the app.")
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
