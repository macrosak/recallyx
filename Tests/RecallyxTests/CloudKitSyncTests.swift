import AppKit
import CoreData
import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Hermetic coverage for the opt-in iCloud (CloudKit) text sync. Real 2-Mac
/// sync is NOT unit-testable (needs the account + devices) — see the PR's
/// attended-verification note. These tests cover the toggle, the mirroring
/// gate, the privacy-before-store guarantee, and the missing-local-image
/// degradation, all without touching real CloudKit or the system clipboard.
@MainActor
@Suite("CloudKit sync (Phase 1)")
struct CloudKitSyncTests {

    // MARK: - Setting round-trips

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "recallyx.tests.\(UUID().uuidString)")!
    }

    @Test func iCloudSync_defaultsOff() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.settings.iCloudSyncEnabled == false)
    }

    @Test func iCloudSync_roundTrips() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.settings.iCloudSyncEnabled = true
        store.flush()

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.iCloudSyncEnabled == true)
    }

    @Test func iCloudSync_absentKeyDecodesOff() throws {
        // An older blob without the key must decode to OFF — no install starts
        // syncing to iCloud without an explicit opt-in.
        let defaults = makeDefaults()
        let partial = try JSONSerialization.data(withJSONObject: ["retentionCap": 500])
        defaults.set(partial, forKey: SettingsStore.storageKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.iCloudSyncEnabled == false)
    }

    // MARK: - Mirroring gate

    @Test func cloudKitOptions_nilWhenDisabled() {
        #expect(PersistenceController.cloudKitOptions(enabled: false) == nil)
    }

    @Test func cloudKitOptions_setWhenEnabled() {
        let opts = PersistenceController.cloudKitOptions(enabled: true)
        #expect(opts != nil)
        #expect(opts?.containerIdentifier == PersistenceController.cloudKitContainerIdentifier)
        // The identifier is derived from the PUBLIC bundle id — carries no team id.
        #expect(PersistenceController.cloudKitContainerIdentifier == "iCloud.io.github.macrosak.recallyx")
    }

    @Test func description_mirroringOffByDefault() {
        // The built store description carries no CloudKit options when off.
        let desc = PersistenceController.makeStoreDescription(inMemory: true, cloudSyncEnabled: false)
        #expect(desc.cloudKitContainerOptions == nil)
    }

    @Test func description_mirroringOnWhenEnabled() {
        // The flag attaches the CloudKit options to the store description. We
        // assert the description — NOT a loaded container: loading a mirrored
        // store in this unentitled test process crashes the CloudKit delegate.
        let desc = PersistenceController.makeStoreDescription(inMemory: true, cloudSyncEnabled: true)
        #expect(desc.cloudKitContainerOptions != nil)
        #expect(desc.cloudKitContainerOptions?.containerIdentifier == PersistenceController.cloudKitContainerIdentifier)
    }

    @Test func liveStore_mirroringOffByDefault_loadsClean() {
        // A live in-memory controller with sync OFF loads a plain local store —
        // no CloudKit delegate, so this is safe to construct in tests.
        let controller = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        #expect(controller.container.persistentStoreDescriptions.first?.cloudKitContainerOptions == nil)
    }

    // MARK: - Privacy filter runs before any store write

    private func freshBoard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.macrosak.recallyx.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private func makeHistoryStore() -> (HistoryStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-tests-\(UUID().uuidString)", isDirectory: true)
        return (HistoryStore(baseURL: base), base)
    }

    @Test func concealedClip_neverReachesStore() {
        // A password-manager (concealed) clip must NOT reach the store when
        // "Capture sensitive data" is off — so it can never be synced either.
        let (store, base) = makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let pb = freshBoard()
        let watcher = ClipboardWatcher(store: store, captureSensitive: { false }, pasteboard: pb)

        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType(PrivacyFilter.concealedType))
        pb.clearContents()
        pb.writeObjects([item])

        watcher.tick()
        #expect(store.items.isEmpty, "the privacy filter must gate the store write")
    }

    @Test func plainClip_reachesStore() {
        // Control: a plain clip DOES reach the store — proving the gate above is
        // the privacy filter, not the watcher failing to capture at all.
        let (store, base) = makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let pb = freshBoard()
        let watcher = ClipboardWatcher(store: store, captureSensitive: { false }, pasteboard: pb)

        pb.clearContents()
        pb.setString("just a normal clip", forType: .string)

        watcher.tick()
        #expect(store.items.count == 1)
        #expect(store.items.first?.text == "just a normal clip")
    }

    // MARK: - Missing-local-image degrades gracefully (never crashes)

    private func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func missingLocalImage_imageURLDoesNotCrashAndItemSurvives() {
        // Phase-1 limitation: an image clip synced from another Mac carries
        // metadata + an imageFilename whose PNG is NOT present locally (images
        // aren't synced yet). The store must still hand back a URL (for the
        // preview to attempt), the file is genuinely absent, and the metadata
        // row survives — no crash.
        let (store, base) = makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let png = tinyPNG()
        let id = store.add(CapturedClip(
            kind: .image, text: nil, imageData: png, preview: "Image · 2 × 2",
            byteSize: png.count, sourceAppBundleID: nil, sourceAppName: nil,
            sourceAppPath: nil, contentHash: ContentHash.of(bytes: png), imageDimensions: "2 × 2"
        ))
        let item = store.items.first { $0.id == id }!

        // Simulate the other-Mac reality: the local PNG is gone.
        let url = store.imageURL(for: item)!
        try? FileManager.default.removeItem(at: url)

        // imageURL still resolves (non-crashing) and the metadata row survives.
        #expect(store.imageURL(for: item) != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.items.contains { $0.id == id })
    }

    @Test func missingLocalImage_previewLoadReturnsNilNotCrash() async {
        // The detail-pane preview loader degrades to nil (→ "missing image"
        // placeholder in DetailPaneView) for a filename with no file on disk.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-tests-\(UUID().uuidString)", isDirectory: true)
        let missing = base.appendingPathComponent("does-not-exist.png")

        let image = await ImagePreviewCache.shared.load(filename: "does-not-exist-\(UUID().uuidString).png", url: missing)
        #expect(image == nil)
    }
}
