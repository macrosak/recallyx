import Foundation
import Testing
@testable import Recallyx

@MainActor
@Suite("SettingsGeneralView")
struct SettingsGeneralViewTests {
    @Test func relaunchButtonVisible_whenLiveValueDriftsFromLaunch() {
        #expect(SettingsGeneralView.relaunchButtonVisible(current: true, launchValue: false))
        #expect(SettingsGeneralView.relaunchButtonVisible(current: false, launchValue: true))
    }

    @Test func relaunchButtonHidden_whenLiveValueMatchesLaunch() {
        #expect(!SettingsGeneralView.relaunchButtonVisible(current: true, launchValue: true))
        #expect(!SettingsGeneralView.relaunchButtonVisible(current: false, launchValue: false))
    }
}
