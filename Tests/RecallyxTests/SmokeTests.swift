import Foundation
import Testing
@testable import Recallyx

/// Placeholder so the test target resolves from commit 1. Real unit tests for
/// HistoryStore / privacy filter / fuzzy matcher / ActionRunner land alongside
/// their components in later commits. Run with `./scripts/test.sh`.
@Suite("Smoke")
struct SmokeTests {
    @Test func appStatusLabels() {
        #expect(AppStatus.idle.menuLabel == "Ready")
        #expect(AppStatus.working.menuLabel == "Working…")
    }
}
