import AppKit
import Testing
@testable import Recallyx
@testable import RecallyxCore

@Suite("PrivacyFilter")
struct PrivacyFilterTests {
    private let plain: [NSPasteboard.PasteboardType] = [.string]
    private let concealed: [NSPasteboard.PasteboardType] = [.string, PrivacyFilter.concealedType]
    private let transient: [NSPasteboard.PasteboardType] = [.string, PrivacyFilter.transientType]

    @Test func plainText_alwaysCaptured() {
        #expect(PrivacyFilter.shouldCapture(types: plain, captureSensitive: false))
        #expect(PrivacyFilter.shouldCapture(types: plain, captureSensitive: true))
    }

    @Test func concealed_skippedWhenSensitiveOff() {
        #expect(!PrivacyFilter.shouldCapture(types: concealed, captureSensitive: false))
    }

    @Test func concealed_capturedWhenSensitiveOn() {
        #expect(PrivacyFilter.shouldCapture(types: concealed, captureSensitive: true))
    }

    @Test func transient_skippedWhenSensitiveOff() {
        #expect(!PrivacyFilter.shouldCapture(types: transient, captureSensitive: false))
    }

    @Test func emptyOrWhitespaceText_isSkippable() {
        #expect(PrivacyFilter.isSkippableText(""))
        #expect(PrivacyFilter.isSkippableText("   \n\t "))
        #expect(!PrivacyFilter.isSkippableText("hello"))
        #expect(!PrivacyFilter.isSkippableText("  hi  "))
    }
}
