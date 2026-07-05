import Foundation

/// The small origin badge shown when a clip was captured on a *different*
/// device than the one currently viewing it — a mac icon for a clip that
/// synced in from another Mac, an iPhone icon for one captured on the phone.
public enum OriginBadgeKind: Equatable, Sendable {
    case mac
    case iphone
    /// A recognized-but-different device whose `sourceDeviceType` isn't "mac"
    /// or "iphone" (a future device kind) — still worth flagging as "elsewhere".
    case other

    /// SF Symbol name for the badge glyph.
    public var systemImageName: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        case .other: return "questionmark.circle"
        }
    }
}

/// Pure helper deciding whether/how to badge a clip's origin device. Shared by
/// the mac panel row (`HistoryRowView`) and the iOS list row (`ClipRow`).
public enum ClipOrigin {
    /// The badge to show for `item` when viewed on a device named
    /// `currentDeviceName`, or `nil` when no badge is warranted: the item has
    /// no recorded device (a pre-feature clip, or a capture path that doesn't
    /// tag one), or its device name matches the current one.
    public static func originBadge(for item: HistoryItem, currentDeviceName: String?) -> OriginBadgeKind? {
        guard let deviceName = item.sourceDeviceName, !deviceName.isEmpty else { return nil }
        guard deviceName != currentDeviceName else { return nil }
        switch item.sourceDeviceType {
        case "mac": return .mac
        case "iphone": return .iphone
        default: return .other
        }
    }
}
