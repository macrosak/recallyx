import Foundation
import Testing
@testable import RecallyxCore

/// `ClipOrigin.originBadge` — the pure helper deciding whether/how to badge a
/// clip's origin device, shared by the mac panel row and the iOS list row.
@Suite("ClipOrigin")
struct ClipOriginTests {
    private func item(deviceName: String?, deviceType: String?) -> HistoryItem {
        let now = Date()
        return HistoryItem(
            id: UUID(), kind: .text, text: "x", preview: "x", byteSize: 1,
            createdAt: now, lastUsedAt: now, contentHash: UUID().uuidString,
            sourceDeviceName: deviceName, sourceDeviceType: deviceType
        )
    }

    @Test func noRecordedDevice_noBadge() {
        let clip = item(deviceName: nil, deviceType: nil)
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == nil)
    }

    @Test func sameDeviceName_noBadge() {
        let clip = item(deviceName: "My Mac", deviceType: "mac")
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == nil)
    }

    @Test func differentDevice_mac_showsLaptopBadge() {
        let clip = item(deviceName: "Michal's MacBook Pro", deviceType: "mac")
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == .mac)
    }

    @Test func differentDevice_iphone_showsPhoneBadge() {
        let clip = item(deviceName: "Michal's iPhone", deviceType: "iphone")
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == .iphone)
    }

    @Test func differentDevice_unknownType_showsOtherBadge() {
        let clip = item(deviceName: "Some Device", deviceType: "android")
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == .other)
    }

    @Test func differentDevice_nilType_showsOtherBadge() {
        let clip = item(deviceName: "Some Device", deviceType: nil)
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == .other)
    }

    @Test func emptyDeviceName_noBadge() {
        let clip = item(deviceName: "", deviceType: "mac")
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: "My Mac") == nil)
    }

    @Test func nilCurrentDeviceName_stillBadgesADifferentlyNamedClip() {
        // When the current device's own name can't be resolved, err toward
        // showing the badge rather than silently hiding all of them.
        let clip = item(deviceName: "Michal's MacBook Pro", deviceType: "mac")
        #expect(ClipOrigin.originBadge(for: clip, currentDeviceName: nil) == .mac)
    }

    @Test func systemImageNames() {
        #expect(OriginBadgeKind.mac.systemImageName == "laptopcomputer")
        #expect(OriginBadgeKind.iphone.systemImageName == "iphone")
        #expect(OriginBadgeKind.other.systemImageName == "questionmark.circle")
    }
}
