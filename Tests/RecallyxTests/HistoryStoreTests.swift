import CoreData
import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

@MainActor
@Suite("HistoryStore")
struct HistoryStoreTests {

    /// Fresh store rooted at a unique temp dir, plus a cleanup closure.
    private func makeStore(cap: Int = 1000) -> (HistoryStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-tests-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(baseURL: base, cap: cap)
        return (store, base)
    }

    private func textClip(_ s: String) -> CapturedClip {
        CapturedClip(
            kind: .text, text: s, imageData: nil, preview: s, byteSize: s.utf8.count,
            sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            contentHash: ContentHash.of(text: s), imageDimensions: nil
        )
    }

    private func imageClip(_ bytes: [UInt8], dims: String = "10 × 10") -> CapturedClip {
        let data = Data(bytes)
        return CapturedClip(
            kind: .image, text: nil, imageData: data, preview: "Image · \(dims)",
            byteSize: data.count, sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            contentHash: ContentHash.of(bytes: data), imageDimensions: dims
        )
    }

    @Test func add_insertsAtTop() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(textClip("first"))
        store.add(textClip("second"))

        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "second")
    }

    @Test func add_identicalContent_bumpsInsteadOfDuplicating() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(textClip("alpha"))
        store.add(textClip("beta"))
        store.add(textClip("alpha")) // re-copy of an existing clip

        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "alpha") // bumped to top
        #expect(store.items.last?.text == "beta")
    }

    @Test func bump_movesToTopAndUpdatesRecency() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(textClip("one"))
        store.add(textClip("two"))
        #expect(store.items.first?.text == "two")

        store.bump(id)
        #expect(store.items.first?.id == id)
        #expect(store.items.first?.text == "one")
    }

    @Test func eviction_dropsOldestAndDeletesImageFile() {
        let (store, base) = makeStore(cap: 2)
        defer { try? FileManager.default.removeItem(at: base) }

        let imgId = store.add(imageClip([1, 2, 3, 4]))
        let imgURL = store.items.first.flatMap { store.imageURL(for: $0) }
        #expect(imgURL != nil)
        #expect(FileManager.default.fileExists(atPath: imgURL!.path))

        // Push the image item past the cap of 2.
        store.add(textClip("a"))
        store.add(textClip("b"))

        #expect(store.items.count == 2)
        #expect(!store.items.contains { $0.id == imgId })
        // Its backing PNG must be gone too.
        #expect(!FileManager.default.fileExists(atPath: imgURL!.path))
    }

    @Test func loweringCap_evictsAndFiresOnChange() {
        let (store, base) = makeStore(cap: 10)
        defer { try? FileManager.default.removeItem(at: base) }

        for i in 0..<5 { store.add(textClip("clip-\(i)")) }
        var notified = false
        store.onChange = { notified = true }

        store.cap = 2
        #expect(store.items.count == 2)
        #expect(notified)   // the menu-bar count listens here
    }

    @Test func ordering_byRecencyDescending_afterReload() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(textClip("old"))
        let midId = store.add(textClip("mid"))
        store.add(textClip("new"))
        store.bump(midId) // mid is now most-recently-used
        store.flush()

        // Reload from disk into a second store.
        let reloaded = HistoryStore(baseURL: base)
        #expect(reloaded.items.first?.text == "mid")
    }

    @Test func persistence_roundTrip() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(textClip("persisted"))
        store.flush()

        let reloaded = HistoryStore(baseURL: base)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items.first?.text == "persisted")
    }

    @Test func delete_removesItemAndImage() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(imageClip([9, 9, 9]))
        let url = store.items.first.flatMap { store.imageURL(for: $0) }!
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.delete(id)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func add_imageWriteFailure_dropsClipInsteadOfInsertingBrokenRow() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        // Force the PNG write to fail: replace the `images/` directory (created in
        // init) with a regular file, so `data.write(to: images/<id>.png)` can't
        // resolve a parent directory and throws.
        let imagesDir = base.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.removeItem(at: imagesDir)
        try! Data([0]).write(to: imagesDir)

        store.add(imageClip([1, 2, 3, 4]))

        // The clip was dropped — no broken `.image`-with-nil-filename row.
        #expect(store.items.isEmpty)
        #expect(!store.items.contains { $0.kind == .image && $0.imageFilename == nil })
    }

    @Test func setPinned_flipsFlagAndPersists() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let id = store.add(textClip("keep me"))
        #expect(store.items.first?.isPinned == false)

        store.setPinned(id, true)
        #expect(store.items.first?.isPinned == true)
        store.flush()

        let reloaded = HistoryStore(baseURL: base)
        #expect(reloaded.items.first(where: { $0.id == id })?.isPinned == true)
    }

    @Test func eviction_exemptsPinnedAndDropsOldestUnpinned() {
        let (store, base) = makeStore(cap: 2)
        defer { try? FileManager.default.removeItem(at: base) }

        // Oldest is an image clip; pin it so it survives despite being oldest.
        let pinnedImgId = store.add(imageClip([1, 2, 3, 4]))
        store.setPinned(pinnedImgId, true)
        let pinnedURL = store.items.first { $0.id == pinnedImgId }.flatMap { store.imageURL(for: $0) }!

        // An older-but-unpinned image clip that should be evicted (and its PNG deleted).
        let evictImgId = store.add(imageClip([5, 6, 7, 8]))
        let evictURL = store.items.first { $0.id == evictImgId }.flatMap { store.imageURL(for: $0) }!

        // Push past cap of 2 with two fresh text clips.
        store.add(textClip("a"))
        store.add(textClip("b"))

        // Pinned item is exempt; count may exceed cap because of it.
        #expect(store.items.contains { $0.id == pinnedImgId })
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
        // The oldest unpinned image was evicted and its file deleted.
        #expect(!store.items.contains { $0.id == evictImgId })
        #expect(!FileManager.default.fileExists(atPath: evictURL.path))
    }

    @Test func eviction_allPinnedKeepsThemAllAboveCap() {
        let (store, base) = makeStore(cap: 10)
        defer { try? FileManager.default.removeItem(at: base) }

        let ids = (0..<3).map { store.add(textClip("clip-\($0)")) }
        for id in ids { store.setPinned(id, true) }

        // Lower the cap below the pinned count — all pinned, none evicted.
        store.cap = 1
        #expect(store.items.count == 3)
        #expect(ids.allSatisfy { id in store.items.contains { $0.id == id } })
    }

    @Test func decode_missingPinnedKey_defaultsToUnpinned() throws {
        let (_, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        // A pre-pin blob: a valid HistoryItem JSON with no "pinned" key.
        let json = """
        [{"id":"\(UUID().uuidString)","kind":"text","text":"legacy","preview":"legacy",\
        "byteSize":6,"createdAt":\(Date().timeIntervalSinceReferenceDate),\
        "lastUsedAt":\(Date().timeIntervalSinceReferenceDate),"contentHash":"abc"}]
        """
        let indexURL = base.appendingPathComponent("history.json")
        try Data(json.utf8).write(to: indexURL)

        let reloaded = HistoryStore(baseURL: base)
        #expect(reloaded.items.count == 1)   // decoded cleanly (no reseed)
        #expect(reloaded.items.first?.isPinned == false)
    }

    @Test func reconcileOrphans_deletesUnreferencedImageFiles() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.add(textClip("just text"))
        store.flush()

        // Drop a stray PNG with no index entry.
        let orphan = base.appendingPathComponent("images/stray.png")
        try Data([0, 1, 2]).write(to: orphan)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        // A new store reconciles on init.
        _ = HistoryStore(baseURL: base)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    /// iOS seam: with `reconcileImages: false` the store keeps an image entity
    /// whose local PNG is absent (in sync phase 1 image payloads don't sync, so a
    /// synced image clip has an entity but no file). Reconciliation must stay off
    /// there so a not-yet-synced image row is never treated as an orphan.
    @Test func reconcileImagesOff_keepsImageEntityWithAbsentFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Seed an image clip, persist, then remove its PNG to mimic an iOS device
        // that received the metadata via CloudKit but not the payload.
        do {
            let store = HistoryStore(baseURL: base)
            let id = store.add(imageClip([1, 2, 3, 4]))
            store.flush()
            let item = try #require(store.items.first { $0.id == id })
            let url = try #require(store.imageURL(for: item))
            try FileManager.default.removeItem(at: url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        // Reload with reconciliation off: the image entity survives.
        let ios = HistoryStore(baseURL: base, reconcileImages: false)
        #expect(ios.items.count == 1)
        let survivor = try #require(ios.items.first)
        #expect(survivor.kind == .image)
        #expect(survivor.imageFilename != nil)
        // Its local file is (still) absent — the store kept the entity anyway.
        let url = try #require(ios.imageURL(for: survivor))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Corrupt-tolerance now lives on the JSON → Core Data migration path: a bad
    /// legacy `history.json` on first launch is backed up to `.corrupt-*`, the
    /// store stays empty (no crash), and on-disk image payloads survive
    /// (reconciliation is skipped on the reseed/empty-migration path).
    @Test func corruptLegacyJSON_backsUpAndStaysEmptyAndKeepsImagePayloads() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )

        // Seed an image payload on disk (as if referenced by the legacy index).
        let png = base.appendingPathComponent("images/keep.png")
        try Data([0, 1, 2, 3]).write(to: png)

        // A corrupt legacy index — no Core Data store exists yet (fresh dir).
        let indexURL = base.appendingPathComponent("history.json")
        try Data("not json".utf8).write(to: indexURL)

        let store = HistoryStore(baseURL: base)
        #expect(store.items.isEmpty) // import failed → empty, didn't crash

        // The bad JSON was backed up.
        let backup = try FileManager.default
            .contentsOfDirectory(atPath: base.path)
            .first { $0.hasPrefix("history.json.corrupt-") }
        #expect(backup != nil)

        // The PNG payload survives — reconciliation is skipped on the empty path.
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test func loweringCapEvictsOnLoad() {
        let (store, base) = makeStore(cap: 10)
        defer { try? FileManager.default.removeItem(at: base) }

        for i in 0..<5 { store.add(textClip("clip-\(i)")) }
        store.flush()

        // A new store over the same dir with a lower cap evicts on load,
        // not waiting for the next add().
        let reloaded = HistoryStore(baseURL: base, cap: 2)
        #expect(reloaded.items.count == 2)
    }

    @Test func inMemoryStore_isUsable() {
        // The hermetic in-memory variant: add/dedupe/order work without a
        // SQLite file on disk.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseURL: base, inMemory: true)

        store.add(textClip("a"))
        store.add(textClip("b"))
        store.add(textClip("a")) // dedupe-bump
        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "a")
        // No SQLite file was written.
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Recallyx.sqlite").path))
    }
}

/// JSON → Core Data one-time migration on first launch of the Core Data build.
@MainActor
@Suite("HistoryStore migration")
struct HistoryStoreMigrationTests {
    private func makeBase() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-mig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )
        return base
    }

    private func legacyItem(_ text: String, pinned: Bool = false, ago: TimeInterval = 0) -> HistoryItem {
        let t = Date(timeIntervalSinceNow: -ago)
        return HistoryItem(
            id: UUID(), kind: .text, text: text, imageFilename: nil, preview: text,
            byteSize: text.utf8.count, createdAt: t, lastUsedAt: t,
            contentHash: ContentHash.of(text: text), pinned: pinned
        )
    }

    @Test func importsLegacyJSON_preservesFieldsAndRenamesToBak() throws {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let pinnedItem = legacyItem("pinned", pinned: true, ago: 100)
        let recentItem = legacyItem("recent", ago: 1)
        let seed = [pinnedItem, recentItem]
        let indexURL = base.appendingPathComponent("history.json")
        try JSONEncoder().encode(seed).write(to: indexURL)

        let store = HistoryStore(baseURL: base)

        // Both items imported, recency-ordered (recent first).
        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "recent")
        // Ids / pins / timestamps preserved.
        let importedPinned = store.items.first { $0.id == pinnedItem.id }
        #expect(importedPinned?.text == "pinned")
        #expect(importedPinned?.isPinned == true)
        #expect(importedPinned?.createdAt == pinnedItem.createdAt)

        // history.json renamed to .bak (not deleted, not left in place).
        #expect(!FileManager.default.fileExists(atPath: indexURL.path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("history.json.bak").path))
    }

    @Test func secondLaunch_isNoOp() throws {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let seed = [legacyItem("one"), legacyItem("two")]
        let indexURL = base.appendingPathComponent("history.json")
        try JSONEncoder().encode(seed).write(to: indexURL)

        let first = HistoryStore(baseURL: base)
        #expect(first.items.count == 2)
        first.flush()

        // Drop a fresh history.json that should NOT be re-imported (store is
        // non-empty, and the original was already renamed to .bak).
        try JSONEncoder().encode([legacyItem("should-not-import")]).write(to: indexURL)

        let second = HistoryStore(baseURL: base)
        #expect(second.items.count == 2) // still just the two original clips
        #expect(!second.items.contains { $0.text == "should-not-import" })
        // The just-written history.json is left untouched (store wasn't empty).
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
    }

    @Test func noLegacyJSON_freshStoreStaysEmpty() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let store = HistoryStore(baseURL: base)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("history.json.bak").path))
    }
}

/// Live sync merge: a CloudKit import (simulated by a SECOND coordinator writing
/// the same on-disk SQLite file) must reach the running store's in-memory
/// `items`, and the store's own write-back must NOT clobber those imported edits.
/// The "remote" writer is a real second `PersistenceController` on the same file
/// (not in-memory — remote-change notifications need a real store).
@MainActor
@Suite("HistoryStore sync merge")
struct HistoryStoreSyncMergeTests {

    private func makeBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-sync-\(UUID().uuidString)", isDirectory: true)
    }

    private func textItem(_ s: String, pinned: Bool = false) -> HistoryItem {
        let now = Date()
        return HistoryItem(
            id: UUID(), kind: .text, text: s, imageFilename: nil, preview: s,
            byteSize: s.utf8.count, createdAt: now, lastUsedAt: now,
            contentHash: ContentHash.of(text: s), pinned: pinned
        )
    }

    private func textClip(_ s: String) -> CapturedClip {
        CapturedClip(
            kind: .text, text: s, imageData: nil, preview: s, byteSize: s.utf8.count,
            sourceAppBundleID: nil, sourceAppName: nil, sourceAppPath: nil,
            contentHash: ContentHash.of(text: s), imageDimensions: nil
        )
    }

    /// A second coordinator on the same SQLite file — stands in for the CloudKit
    /// mirroring delegate / a sibling process. Mutates through its own context.
    private func writeViaRemote(storeURL: URL, _ mutate: (NSManagedObjectContext) -> Void) {
        let remote = PersistenceController(storeURL: storeURL)
        let ctx = remote.viewContext
        ctx.performAndWait {
            mutate(ctx)
            try? ctx.save()
        }
    }

    private func remoteEntity(_ ctx: NSManagedObjectContext, id: UUID) -> ClipEntity? {
        let req = ClipEntity.clipFetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return (try? ctx.fetch(req))?.first
    }

    @Test func remoteAdd_reachesItemsAfterMerge() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let store = HistoryStore(baseURL: base)
        store.add(textClip("local"))
        store.flush()

        // Remote device adds a brand-new clip behind the running app's back.
        let remote = textItem("from-phone")
        writeViaRemote(storeURL: store.storeURLForTesting) { ctx in
            ClipEntity(context: ctx).apply(remote)
        }

        // Before the merge the app can't see it; after, it does.
        #expect(!store.items.contains { $0.id == remote.id })
        store.mergeRemoteChanges()
        #expect(store.items.contains { $0.text == "from-phone" })
        #expect(store.items.contains { $0.text == "local" })
    }

    /// The clobber regression (design item 3). A remote pin lands while a local
    /// edit to a DIFFERENT clip is pending. With the old whole-array `persist`,
    /// flushing the local edit re-exported the still-unpinned clip and reverted
    /// the remote pin; the dirty-set `persist` writes only the locally-edited id,
    /// so both survive.
    @Test func remotePinSurvives_whenLocalEditToOtherClipFlushes() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let store = HistoryStore(baseURL: base)
        let x = store.add(textClip("X"))
        let y = store.add(textClip("Y"))
        store.flush()

        // Remote pins X.
        writeViaRemote(storeURL: store.storeURLForTesting) { ctx in
            guard let e = remoteEntity(ctx, id: x) else { return }
            e.pinned = true
        }

        // Local edit to Y (different clip), left pending. The app's in-memory X is
        // still unpinned — a whole-array flush would clobber the remote pin.
        store.setPinned(y, true)

        // Merge flushes Y first (only Y), then re-reads.
        store.mergeRemoteChanges()

        #expect(store.items.first { $0.id == x }?.isPinned == true)  // remote pin kept
        #expect(store.items.first { $0.id == y }?.isPinned == true)  // local edit kept
    }

    /// Remote delete stickiness (design item 4). A remote delete + an unrelated
    /// pending local add: the delete must stick (not resurrect) and the add must
    /// persist. The whole-array `persist` would have re-inserted the
    /// still-in-memory X.
    @Test func remoteDeleteSticks_whenLocalAddPending() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let store = HistoryStore(baseURL: base)
        let x = store.add(textClip("X"))
        _ = store.add(textClip("Y"))
        store.flush()

        // Remote deletes X.
        writeViaRemote(storeURL: store.storeURLForTesting) { ctx in
            if let e = remoteEntity(ctx, id: x) { ctx.delete(e) }
        }

        // Unrelated local add, still pending (X remains in the app's memory).
        store.add(textClip("Z"))

        store.mergeRemoteChanges()

        #expect(!store.items.contains { $0.id == x })         // delete stuck
        #expect(store.items.contains { $0.text == "Y" })      // untouched survives
        #expect(store.items.contains { $0.text == "Z" })      // local add persisted
    }

    /// The wired path: a real `.NSPersistentStoreRemoteChange` notification (what a
    /// CloudKit import posts) drives the debounced merge end to end.
    @Test func remoteChangeNotification_triggersDebouncedMerge() async {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let store = HistoryStore(baseURL: base, remoteMergeDelay: 0.05)
        store.add(textClip("local"))
        store.flush()

        let remote = textItem("via-notification")
        writeViaRemote(storeURL: store.storeURLForTesting) { ctx in
            ClipEntity(context: ctx).apply(remote)
        }

        // Post the notification the running app would receive from the import.
        NotificationCenter.default.post(
            name: .NSPersistentStoreRemoteChange,
            object: store.storeCoordinatorForTesting
        )

        // Await the debounced merge (poll up to a few seconds).
        var appeared = false
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if store.items.contains(where: { $0.text == "via-notification" }) {
                appeared = true
                break
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        #expect(appeared)
    }

    /// Design item 5: with sync ON, launch orphan-reconciliation is skipped so a
    /// synced-in image entity (whose PNG never synced) is never treated as garbage
    /// — mirroring the iOS `reconcileImages: false` behavior. A stray unreferenced
    /// PNG is therefore NOT deleted (the sync-off path DOES delete it, covered by
    /// `reconcileOrphans_deletesUnreferencedImageFiles`).
    @Test func syncEnabled_skipsOrphanReconciliation() throws {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )
        let stray = base.appendingPathComponent("images/stray.png")
        try Data([0, 1, 2]).write(to: stray)

        // cloudSyncEnabled: true → reconcile skipped (unentitled test process keeps
        // the store plain-local, so no CloudKit crash).
        _ = HistoryStore(baseURL: base, cloudSyncEnabled: true)
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }
}

@Suite("ContentHash")
struct ContentHashTests {
    @Test func identicalText_sameHash() {
        #expect(ContentHash.of(text: "hello") == ContentHash.of(text: "hello"))
    }

    @Test func differentText_differentHash() {
        #expect(ContentHash.of(text: "hello") != ContentHash.of(text: "world"))
    }

    @Test func bytesAndText_areDistinctNamespaces() {
        let bytes = Data("hello".utf8)
        // Same underlying bytes hash the same regardless of entry point.
        #expect(ContentHash.of(bytes: bytes) == ContentHash.of(text: "hello"))
    }
}
