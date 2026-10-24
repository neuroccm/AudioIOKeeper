import Foundation
import OSLog
import ServiceManagement

/// Launch-at-login management via the modern `SMAppService` API (macOS 13+).
@MainActor
enum LoginItemManager {
    private static let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "LoginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
        }
    }
}
