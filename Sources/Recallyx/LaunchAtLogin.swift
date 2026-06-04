import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`. macOS 13+ only — matches our
/// platform floor. Copied from AI Replace.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` ⇒ registers the app to launch at login; `false` ⇒ unregisters.
    /// Throws if SMAppService rejects the change (e.g. the user disabled the app
    /// in System Settings → Login Items and we can't re-enable from here).
    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else {
            if service.status == .enabled { try service.unregister() }
        }
    }
}
