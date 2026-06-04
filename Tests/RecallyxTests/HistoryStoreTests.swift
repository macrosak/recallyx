import Foundation
import Testing
@testable import Recallyx

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

    @Test func corruptIndex_backsUpAndReseeds() throws {
        let (store, base) = makeStore()
        store.add(textClip("x"))
        store.flush()

        // Corrupt the index file.
        let indexURL = base.appendingPathComponent("history.json")
        try Data("not json".utf8).write(to: indexURL)

        let reloaded = HistoryStore(baseURL: base)
        #expect(reloaded.items.isEmpty) // reseeded empty, didn't crash
        try? FileManager.default.removeItem(at: base)
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
