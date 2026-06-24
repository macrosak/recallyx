import AppKit
import Foundation
import RecallyxCore

/// Polls `NSPasteboard.general.changeCount` (~0.3s) and turns each change into a
/// `CapturedClip` for `HistoryStore`. Applies the privacy filter, classifies
/// text vs image, captures the frontmost app for provenance, and guards against
/// re-capturing its own writes.
@MainActor
final class ClipboardWatcher {
    private let store: HistoryStore
    /// Reads the live "Capture sensitive data" setting (wired to Settings in a
    /// later commit; defaults off).
    private let captureSensitive: () -> Bool

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    /// `changeCount`s produced by our own pasteboard writes (paste/copy of an
    /// existing clip). A tick observing one of these is skipped so we don't
    /// churn provenance or double-count. Keyed by changeCount, not content
    /// hash: a re-encoded image (NSImage → TIFF → PNG) never hashes back to
    /// the originally captured bytes, so a hash key would miss its own write
    /// AND poison future legitimate captures of the original. AI/script
    /// results are *not* marked, so they re-enter history as fresh top items.
    private var selfWriteChangeCounts: Set<Int> = []

    init(store: HistoryStore, captureSensitive: @escaping () -> Bool) {
        self.store = store
        self.captureSensitive = captureSensitive
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("clipboard watcher started (changeCount=\(lastChangeCount))")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Tell the watcher the pasteboard's current state is our own write — call
    /// immediately AFTER setting the pasteboard, so the recorded changeCount is
    /// the one our write produced.
    func markSelfWrite() {
        selfWriteChangeCounts.insert(pasteboard.changeCount)
    }

    // MARK: - Polling

    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let isSelfWrite = selfWriteChangeCounts.contains(current)
        // changeCount only grows — anything at or below the observed value is
        // spent (a marked write superseded within one tick can never match).
        selfWriteChangeCounts = selfWriteChangeCounts.filter { $0 > current }
        if isSelfWrite {
            Log.debug("clipboard tick: self-write, skipped changeCount=\(current)")
            return
        }

        let types = pasteboard.types ?? []
        guard PrivacyFilter.shouldCapture(types: types.map(\.rawValue), captureSensitive: captureSensitive()) else {
            Log.debug("clipboard tick skipped (privacy hint) types=\(types.map(\.rawValue))")
            return
        }

        guard let captured = classify() else {
            Log.debug("clipboard tick: nothing capturable types=\(types.map(\.rawValue))")
            return
        }

        Log.info("clipboard captured kind=\(captured.kind.rawValue) bytes=\(captured.byteSize) app=\(captured.sourceAppName ?? "?")")
        store.add(captured)
    }

    /// Image takes priority — a screenshot or copied image carries pixel data and
    /// usually no string; styled/plain text carries a string and no image data.
    private func classify() -> CapturedClip? {
        let app = NSWorkspace.shared.frontmostApplication

        if let (png, dims) = readImagePNG() {
            let hash = ContentHash.of(bytes: png)
            return CapturedClip(
                kind: .image, text: nil, imageData: png,
                preview: "Image · \(dims)", byteSize: png.count,
                sourceAppBundleID: app?.bundleIdentifier,
                sourceAppName: app?.localizedName,
                sourceAppPath: app?.bundleURL?.path,
                contentHash: hash, imageDimensions: dims
            )
        }

        if let text = pasteboard.string(forType: .string), !PrivacyFilter.isSkippableText(text) {
            return CapturedClip(
                kind: .text, text: text, imageData: nil,
                preview: Self.snippet(text), byteSize: text.utf8.count,
                sourceAppBundleID: app?.bundleIdentifier,
                sourceAppName: app?.localizedName,
                sourceAppPath: app?.bundleURL?.path,
                contentHash: ContentHash.of(text: text), imageDimensions: nil
            )
        }

        return nil
    }

    /// Read the pasteboard image as PNG bytes + a "W × H" dimension string.
    private func readImagePNG() -> (Data, String)? {
        let rep: NSBitmapImageRep?
        if let pngData = pasteboard.data(forType: .png), let r = NSBitmapImageRep(data: pngData) {
            rep = r
        } else if let tiff = pasteboard.data(forType: .tiff), let r = NSBitmapImageRep(data: tiff) {
            rep = r
        } else {
            rep = nil
        }
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dims = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        return (png, dims)
    }

    /// A trimmed, length-capped preview for the list row (the row clamps lines).
    private static func snippet(_ text: String, max: Int = 280) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max))
    }
}
