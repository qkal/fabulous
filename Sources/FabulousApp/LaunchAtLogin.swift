import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. Only works when running from a real
/// .app bundle (not `swift run`); errors are surfaced to the settings UI.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
