import CryptoKit
import Foundation

enum ClipKind: String, Codable, Equatable {
    case text
    case image
}

/// One stored clipboard entry. Text lives inline; images are written to
/// `images/<id>.png` and only the filename is stored here. `contentHash` keys
/// dedupe (a re-copy of identical content bumps the existing row to the top).
struct HistoryItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ClipKind
    var text: String?
    var imageFilename: String?
    /// List snippet: a text excerpt, or "Image · 1920 × 1080" for images.
    var preview: String
    var byteSize: Int
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// Path to the source app bundle, for icon resolution even when it isn't running.
    var sourceAppPath: String?
    var createdAt: Date
    var lastUsedAt: Date
    var contentHash: String
    /// Image pixel dimensions, e.g. "1920 × 1080". Nil for text.
    var imageDimensions: String?
    /// User-pinned: sticks to the top of the list and is exempt from cap eviction.
    /// Optional for backward-compatible decode (missing in pre-pin blobs → nil → not pinned).
    var pinned: Bool?

    var isPinned: Bool { pinned ?? false }

    /// Recency key used for ordering — a bump updates `lastUsedAt`, a fresh
    /// capture sets both, so the larger of the two always reflects "most recent".
    var recency: Date { max(createdAt, lastUsedAt) }
}

/// Raw capture from `ClipboardWatcher`, before it becomes a `HistoryItem`.
/// The watcher fills this in; `HistoryStore.add` turns it into a stored record
/// (assigning an id, writing the image file, computing nothing it didn't already).
struct CapturedClip {
    var kind: ClipKind
    var text: String?
    /// PNG bytes for an image capture; nil for text.
    var imageData: Data?
    var preview: String
    var byteSize: Int
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var sourceAppPath: String?
    var contentHash: String
    var imageDimensions: String?
}

/// SHA-256 content hashes for dedupe. Identical content → identical hash;
/// different content → different hash.
enum ContentHash {
    static func of(text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    static func of(bytes: Data) -> String {
        hex(SHA256.hash(data: bytes))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
