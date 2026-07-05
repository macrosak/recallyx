import CoreData
import Foundation
import Testing
@testable import RecallyxCore

/// `ShareClipWriter` writes one shared clip into the app-group store the way the
/// iOS Share Extension does, mirroring `HistoryStore.add`'s insert / dedupe-bump
/// semantics. These tests write via the writer and read back via a `HistoryStore`
/// on the **same** temp store — exercising the sibling-writer round-trip the
/// design depends on (extension writes local, app reads it).
@Suite("ShareClipWriter")
struct ShareClipWriterTests {
    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recallyx-share-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func textClip(_ s: String, device: String? = nil) -> CapturedClip {
        CapturedClip.forText(
            s,
            sourceAppName: "Share Sheet",
            sourceDeviceName: device,
            sourceDeviceType: device == nil ? nil : "iphone"
        )!
    }

    @Test func save_insertsRowReadableByHistoryStore() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let writer = ShareClipWriter(baseURL: base)
        let outcome = writer.save(textClip("shared hello", device: "iPhone"))
        #expect(outcome == .inserted)

        // A fresh HistoryStore on the same file must see the extension's row.
        let store = await MainActor.run { HistoryStore(baseURL: base, reconcileImages: false) }
        let items = await MainActor.run { store.items }
        #expect(items.count == 1)
        #expect(items.first?.text == "shared hello")
        #expect(items.first?.kind == .text)
        #expect(items.first?.sourceAppName == "Share Sheet")
        #expect(items.first?.sourceDeviceName == "iPhone")
        #expect(items.first?.sourceDeviceType == "iphone")
    }

    @Test func save_identicalContentBumpsInsteadOfDuplicating() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let writer = ShareClipWriter(baseURL: base)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)

        #expect(writer.save(textClip("same text"), now: t0) == .inserted)
        // Same content hash → bump, not a second row.
        #expect(writer.save(textClip("same text"), now: t1) == .bumped)

        let store = await MainActor.run { HistoryStore(baseURL: base, reconcileImages: false) }
        let items = await MainActor.run { store.items }
        #expect(items.count == 1)
        // createdAt preserved from the first write; recency bumped to the second.
        #expect(items.first?.createdAt == t0)
        #expect(items.first?.recency == t1)
    }

    @Test func save_distinctContentInsertsSeparateRows() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let writer = ShareClipWriter(baseURL: base)
        #expect(writer.save(textClip("one")) == .inserted)
        #expect(writer.save(textClip("two")) == .inserted)
        #expect(writer.save(textClip("three")) == .inserted)

        let store = await MainActor.run { HistoryStore(baseURL: base, reconcileImages: false) }
        let count = await MainActor.run { store.items.count }
        #expect(count == 3)
    }

    @Test func save_dedupeMatchesAcrossSeparateWriterInstances() async throws {
        // A new extension process (new writer) sharing the same text must still
        // dedupe against a row a prior invocation wrote — the fetch-by-hash path,
        // not an in-memory set.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(ShareClipWriter(baseURL: base).save(textClip("persisted")) == .inserted)
        #expect(ShareClipWriter(baseURL: base).save(textClip("persisted")) == .bumped)

        let store = await MainActor.run { HistoryStore(baseURL: base, reconcileImages: false) }
        let count = await MainActor.run { store.items.count }
        #expect(count == 1)
    }
}
