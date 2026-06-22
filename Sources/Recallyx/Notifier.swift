import AppKit
import Foundation
import UserNotifications
import RecallyxCore

enum NotifierAction: String {
    case openAccessibilitySettings
    case openSettings
}

/// Banner notifications. Copied from AI Replace.
@MainActor
final class Notifier: NSObject {
    private var authorizationRequested = false
    private let delegate = NotificationDelegate()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = delegate
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(body: String, title: String = "Recallyx", action: NotifierAction? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let action {
            content.userInfo = ["action": action.rawValue]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo["action"] as? String,
           let action = NotifierAction(rawValue: raw) {
            Task { @MainActor in Self.handle(action: action) }
        }
        completionHandler()
    }

    @MainActor
    private static func handle(action: NotifierAction) {
        switch action {
        case .openAccessibilitySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .openSettings:
            NotificationCenter.default.post(name: .openRecallyxSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let openRecallyxSettings = Notification.Name("io.github.macrosak.recallyx.openSettings")
}
