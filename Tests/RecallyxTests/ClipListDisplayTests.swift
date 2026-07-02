import Foundation
import Testing
@testable import RecallyxCore

@Suite("ClipListDisplay")
struct ClipListDisplayTests {
    private func text(
        _ preview: String,
        pinned: Bool = false,
        app: String? = nil,
        created: Date = Date(timeIntervalSince1970: 1000),
        id: UUID = UUID()
    ) -> HistoryItem {
        HistoryItem(
            id: id,
            kind: .text,
            text: preview,
            preview: preview,
            byteSize: preview.utf8.count,
            sourceAppName: app,
            createdAt: created,
            lastUsedAt: created,
            contentHash: preview,
            pinned: pinned
        )
    }

    private func image(dimensions: String?, id: UUID = UUID()) -> HistoryItem {
        HistoryItem(
            id: id,
            kind: .image,
            imageFilename: "\(id).png",
            preview: "Image",
            byteSize: 10,
            createdAt: Date(timeIntervalSince1970: 1000),
            lastUsedAt: Date(timeIntervalSince1970: 1000),
            contentHash: id.uuidString,
            imageDimensions: dimensions
        )
    }

    @Test func emptyQuery_isPinnedFirstByRecency() {
        let older = text("alpha", created: Date(timeIntervalSince1970: 100))
        let newer = text("bravo", created: Date(timeIntervalSince1970: 200))
        let pinnedOld = text("charlie", pinned: true, created: Date(timeIntervalSince1970: 50))

        let result = ClipListDisplay.filter([older, newer, pinnedOld], query: "")

        #expect(result.map(\.preview) == ["charlie", "bravo", "alpha"])
    }

    @Test func whitespaceQuery_treatedAsEmpty() {
        let a = text("alpha", created: Date(timeIntervalSince1970: 200))
        let b = text("bravo", created: Date(timeIntervalSince1970: 100))
        #expect(ClipListDisplay.filter([b, a], query: "   ").map(\.preview) == ["alpha", "bravo"])
    }

    @Test func nonEmptyQuery_filtersAndKeepsPinnedFirst() {
        let match1 = text("hello world", created: Date(timeIntervalSince1970: 100))
        let match2 = text("hello there", pinned: true, created: Date(timeIntervalSince1970: 50))
        let noMatch = text("goodbye", created: Date(timeIntervalSince1970: 300))

        let result = ClipListDisplay.filter([match1, match2, noMatch], query: "hello")

        #expect(result.map(\.preview) == ["hello there", "hello world"])
    }

    @Test func rowSubtitle_withApp_joinsWithDot() {
        let item = text("x", app: "Safari", created: Date(timeIntervalSince1970: 0))
        let subtitle = ClipListDisplay.rowSubtitle(for: item, now: Date(timeIntervalSince1970: 120))
        #expect(subtitle == "Safari · 2 min ago")
    }

    @Test func rowSubtitle_withoutApp_isTimeOnly() {
        let item = text("x", app: nil, created: Date(timeIntervalSince1970: 0))
        let subtitle = ClipListDisplay.rowSubtitle(for: item, now: Date(timeIntervalSince1970: 120))
        #expect(subtitle == "2 min ago")
    }

    @Test func rowSubtitle_blankApp_isTimeOnly() {
        let item = text("x", app: "   ", created: Date(timeIntervalSince1970: 0))
        let subtitle = ClipListDisplay.rowSubtitle(for: item, now: Date(timeIntervalSince1970: 3))
        #expect(subtitle == "just now")
    }

    @Test func imagePlaceholderTitle_withDimensions() {
        #expect(ClipListDisplay.imagePlaceholderTitle(for: image(dimensions: "800×600")) == "Image · 800×600")
    }

    @Test func imagePlaceholderTitle_withoutDimensions() {
        #expect(ClipListDisplay.imagePlaceholderTitle(for: image(dimensions: nil)) == "Image")
        #expect(ClipListDisplay.imagePlaceholderTitle(for: image(dimensions: "  ")) == "Image")
    }
}
