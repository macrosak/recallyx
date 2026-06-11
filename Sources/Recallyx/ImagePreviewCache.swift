import AppKit
import Foundation
import ImageIO

/// Maximum display height for a preview image (points). Kept at file scope so
/// `downsample` can read it without a main-actor hop.
private let imagePreviewMaxDisplayHeight: CGFloat = 200

/// Loads and caches downsampled image previews for clipboard clips.
/// Cache hit → synchronous render (no flicker on arrow-key navigation).
/// Cache miss → loads + decodes off the main thread via a .task modifier in
/// DetailPaneView.
///
/// Mirrors AppIconProvider's pattern: @MainActor, NSCache keyed by filename.
@MainActor
final class ImagePreviewCache {
    static let shared = ImagePreviewCache()

    private var cache = NSCache<NSString, NSImage>()

    func image(for filename: String) -> NSImage? {
        cache.object(forKey: filename as NSString)
    }

    /// Load, downsample, and cache an image from `url`.
    /// Returns the cached `NSImage` on success, `nil` if the file is missing or decode fails.
    func load(filename: String, url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: filename as NSString) { return hit }

        // Capture scale on the main actor before hopping off-thread; NSScreen.main
        // is a main-thread-only API and must not be called from the detached task.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Decode off the main thread. Box wraps NSImage for the actor-boundary
        // crossing on macOS 13 where NSImage doesn't formally conform to Sendable.
        let box = await Task.detached(priority: .userInitiated) {
            Box(Self.downsample(url: url, scale: scale))
        }.value

        if let img = box.value {
            cache.setObject(img, forKey: filename as NSString)
            return img
        }
        return nil
    }

    private nonisolated static func downsample(url: URL, scale: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }

        // Target pixels = maxDisplayHeight × backing scale (captured on main actor).
        let targetPx = Int(imagePreviewMaxDisplayHeight * scale)

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPx,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Thin Sendable box for passing a non-Sendable value across an actor boundary
/// when the caller knows the handoff is safe (the value is only used on the
/// receiving actor after the crossing).
private struct Box<T>: @unchecked Sendable {
    let value: T?
    init(_ v: T?) { value = v }
}
