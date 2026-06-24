import Foundation

/// Platform-free seam for resolving a source app's icon. The concrete image type
/// is left to the platform (AppKit `NSImage` on macOS, UIKit `UIImage` on a future
/// iOS target) via the associated type, so this protocol stays AppKit-free and
/// lives in the portable core. The app injects the `NSWorkspace`-backed impl.
@MainActor
public protocol AppIconResolving {
    /// The platform image type the resolver produces (e.g. `NSImage` / `UIImage`).
    associatedtype Icon

    /// Resolve an icon for the given source-app identifiers, memoizing as the
    /// implementation sees fit. Returns `nil` when nothing can be resolved.
    func icon(bundleID: String?, path: String?) -> Icon?
}

public extension AppIconResolving {
    /// Convenience: resolve the icon for a stored clip's source app.
    func icon(for item: HistoryItem) -> Icon? {
        icon(bundleID: item.sourceAppBundleID, path: item.sourceAppPath)
    }
}
