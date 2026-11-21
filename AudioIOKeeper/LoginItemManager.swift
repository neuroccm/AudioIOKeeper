import Foundation
import OSLog
import ServiceManagement

/// Normalized registration state of the login item.
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
}

/// Abstraction over `SMAppService` so `AppModel` can report registration
/// failures and stay testable without touching the host's Login Items.
@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<LoginItemStatus, Error>
    func openSystemSettings()
}

/// Launch-at-login management via the modern `SMAppService` API (macOS 13+).
@MainActor
struct SystemLoginItemManager: LoginItemManaging {
    private static let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "LoginItem")

    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<LoginItemStatus, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(status)
        } catch {
            Self.logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - AppModel integration

extension AppModel {
    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        switch loginItem.setEnabled(enabled) {
        case .success(let updated):
            applyLoginItemStatus(updated)
        case .failure(let error):
            applyLoginItemStatus(loginItem.status)
            loginItemError = error.localizedDescription
        }
    }

    func refreshLoginItemStatus() {
        applyLoginItemStatus(loginItem.status)
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    func applyLoginItemStatus(_ status: LoginItemStatus) {
        launchAtLogin = status == .enabled
        loginItemNeedsApproval = status == .requiresApproval
    }
}
