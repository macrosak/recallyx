import AppKit
import RecallyxCore

/// Resolves a source app's icon as an `NSImage`, memoized by bundle ID. Uses
/// `NSWorkspace.icon(forFile:)` against the app bundle path (works even when the
/// app isn't running), with running-app and generic fallbacks. In-memory cache
/// only — nothing icon-related is persisted beyond the three string fields on
/// `HistoryItem`.
///
/// The AppKit-backed implementation of `RecallyxCore.AppIconResolving`; core code
/// references the protocol, the app injects this. A future iOS target supplies its
/// own `UIImage`-backed conformance.
@MainActor
final class AppIconProvider: AppIconResolving {
    static let shared = AppIconProvider()

    private var cache: [String: NSImage] = [:]

    func icon(bundleID: String?, path: String?) -> NSImage? {
        let key = bundleID ?? path ?? ""
        if let cached = cache[key] { return cached }

        var image: NSImage?
        if let path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        }
        if image == nil, let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }

        if let image {
            cache[key] = image
        }
        return image
    }
}
