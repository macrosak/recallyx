import Foundation
import Testing
@testable import RecallyxCore

@Suite("FirstRunShowcase")
struct FirstRunShowcaseTests {
    // MARK: - shouldSeed truth table

    @Test func shouldSeed_onlyWhenEmptyAndNotHandled() {
        // Both gates must hold — the two-gate contract that keeps a fresh
        // RECALLYX_DATA_DIR (empty store, shared UserDefaults) from re-seeding.
        #expect(FirstRunShowcase.shouldSeed(storeIsEmpty: true, handled: false) == true)
        #expect(FirstRunShowcase.shouldSeed(storeIsEmpty: true, handled: true) == false)
        #expect(FirstRunShowcase.shouldSeed(storeIsEmpty: false, handled: false) == false)
        #expect(FirstRunShowcase.shouldSeed(storeIsEmpty: false, handled: true) == false)
    }

    // MARK: - shouldShowHint

    @Test func shouldShowHint_untilCompleted() {
        #expect(FirstRunShowcase.shouldShowHint(completed: false) == true)
        #expect(FirstRunShowcase.shouldShowHint(completed: true) == false)
    }

    // MARK: - sample content

    @Test func sampleJSON_isValidCompactJSON() throws {
        // The demo target is "Pretty-print JSON" — the sample must actually parse
        // as JSON, and be a single line so it reads as an obvious demo.
        let data = Data(FirstRunShowcase.sampleJSON.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(obj is [String: Any])
        #expect(!FirstRunShowcase.sampleJSON.contains("\n"))
    }

    @Test func sampleMetadata_isPopulated() {
        #expect(FirstRunShowcase.sampleActionName == "Pretty-print JSON")
        #expect(!FirstRunShowcase.sampleSourceAppName.isEmpty)
    }
}
