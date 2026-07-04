import CryptoKit
import Foundation

public enum ClipKind: String, Codable, Equatable, Sendable {
    case text
    case image
}

/// One stored clipboard entry. Text lives inline; images are written to
/// `images/<id>.png` and only the filename is stored here. `contentHash` keys
/// dedupe (a re-copy of identical content bumps the existing row to the top).
public struct HistoryItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ClipKind
    public var text: String?
    public var imageFilename: String?
    /// List snippet: a text excerpt, or "Image · 1920 × 1080" for images.
    public var preview: String
    public var byteSize: Int
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    /// Path to the source app bundle, for icon resolution even when it isn't running.
    public var sourceAppPath: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var contentHash: String
    /// Image pixel dimensions, e.g. "1920 × 1080". Nil for text.
    public var imageDimensions: String?
    /// User-pinned: sticks to the top of the list and is exempt from cap eviction.
    /// Optional for backward-compatible decode (missing in pre-pin blobs → nil → not pinned).
    public var pinned: Bool?

    public init(
        id: UUID,
        kind: ClipKind,
        text: String? = nil,
        imageFilename: String? = nil,
        preview: String,
        byteSize: Int,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        sourceAppPath: String? = nil,
        createdAt: Date,
        lastUsedAt: Date,
        contentHash: String,
        imageDimensions: String? = nil,
        pinned: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFilename = imageFilename
        self.preview = preview
        self.byteSize = byteSize
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.sourceAppPath = sourceAppPath
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.contentHash = contentHash
        self.imageDimensions = imageDimensions
        self.pinned = pinned
    }

    public var isPinned: Bool { pinned ?? false }

    /// Recency key used for ordering — a bump updates `lastUsedAt`, a fresh
    /// capture sets both, so the larger of the two always reflects "most recent".
    public var recency: Date { max(createdAt, lastUsedAt) }
}

/// Raw capture from `ClipboardWatcher`, before it becomes a `HistoryItem`.
/// The watcher fills this in; `HistoryStore.add` turns it into a stored record
/// (assigning an id, writing the image file, computing nothing it didn't already).
public struct CapturedClip {
    public var kind: ClipKind
    public var text: String?
    /// PNG bytes for an image capture; nil for text.
    public var imageData: Data?
    public var preview: String
    public var byteSize: Int
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var sourceAppPath: String?
    public var contentHash: String
    public var imageDimensions: String?

    public init(
        kind: ClipKind,
        text: String? = nil,
        imageData: Data? = nil,
        preview: String,
        byteSize: Int,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        sourceAppPath: String? = nil,
        contentHash: String,
        imageDimensions: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.preview = preview
        self.byteSize = byteSize
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.sourceAppPath = sourceAppPath
        self.contentHash = contentHash
        self.imageDimensions = imageDimensions
    }
}

extension CapturedClip {
    /// Build a text `CapturedClip` from a raw string, or `nil` when the text is
    /// empty / whitespace-only (nothing worth capturing — mirrors the mac
    /// watcher's `isSkippableText` gate). Centralizes the snippet / byteSize /
    /// contentHash derivation so any capture entry point (the mac watcher, the
    /// iOS paste-capture control) agrees on the stored shape. `sourceAppName`
    /// labels the origin (e.g. "iPhone" for an on-device paste).
    public static func forText(
        _ text: String,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppPath: String? = nil
    ) -> CapturedClip? {
        guard !PrivacyFilter.isSkippableText(text) else { return nil }
        return CapturedClip(
            kind: .text,
            text: text,
            imageData: nil,
            preview: snippet(text),
            byteSize: text.utf8.count,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            sourceAppPath: sourceAppPath,
            contentHash: ContentHash.of(text: text),
            imageDimensions: nil
        )
    }

    /// Trimmed, length-capped list-row preview (the row further clamps lines).
    static func snippet(_ text: String, max: Int = 280) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= max ? trimmed : String(trimmed.prefix(max))
    }
}

/// SHA-256 content hashes for dedupe. Identical content → identical hash;
/// different content → different hash.
public enum ContentHash {
    public static func of(text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    public static func of(bytes: Data) -> String {
        hex(SHA256.hash(data: bytes))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
