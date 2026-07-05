import Foundation

/// This Mac's name, tagging every captured clip with its origin device (see
/// `HistoryItem.sourceDeviceName`/`sourceDeviceType`) so a clip synced in from
/// another device can show a small origin badge in the panel row. `Host.current()`
/// isn't free (it's not a pure in-memory read), so it's read **once** here and
/// cached for the process's lifetime — every capture site (the clipboard
/// watcher's poll tick, ⌃⇧V transform-selection, detail-pane copy-selection)
/// and the panel row's badge all reuse this same value, so a clip captured on
/// this Mac always compares equal to "this device".
enum DeviceOrigin {
    static let name: String? = Host.current().localizedName
    static let type = "mac"
}
