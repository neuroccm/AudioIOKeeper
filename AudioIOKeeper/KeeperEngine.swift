import Foundation

/// Pure decision logic for the keeper, isolated from Core Audio so it can be
/// unit-tested without any hardware.
///
/// The keeper's job: when the system default drifts away from the device the
/// user pinned in this app (for example because AirPods were taken out or a
/// phone became available over Continuity), move it back. It never invents a
/// choice of its own and never fights a change the user makes inside the app:
/// in-app selections update the pin itself.
enum KeeperEngine {

    enum Action: Equatable, Sendable {
        /// Nothing to do.
        case none
        /// Restore the given pinned device UID as the system default.
        case restore(uid: String)
    }

    /// Decides what to do for one direction.
    ///
    /// - Parameters:
    ///   - keepingEnabled: whether keeping is enabled for this direction.
    ///   - pinnedUID: the device UID the user pinned, if any.
    ///   - currentUID: the device UID that is currently the system default, if any.
    ///   - availableUIDs: UIDs of devices that are currently present and alive.
    /// - Returns: `.restore` only when keeping is on, a pin exists, the current
    ///   default differs from the pin, and the pinned device is actually
    ///   present. A disconnected pinned device is simply waited for; the
    ///   system default is left alone in the meantime so nothing breaks.
    static func action(
        keepingEnabled: Bool,
        pinnedUID: String?,
        currentUID: String?,
        availableUIDs: Set<String>
    ) -> Action {
        guard keepingEnabled, let pinnedUID else { return .none }
        guard currentUID != pinnedUID else { return .none }
        guard availableUIDs.contains(pinnedUID) else { return .none }
        return .restore(uid: pinnedUID)
    }
}

/// High-level state presented in the UI for one direction.
enum DirectionStatus: Equatable, Sendable {
    /// Keeping is off; the system is free to switch.
    case notKeeping
    /// Keeping is on and the pinned device is the current default.
    case kept
    /// Keeping is on, the default just drifted, and a restore is in flight.
    case restoring
    /// Keeping is on but the pinned device is disconnected right now.
    case waitingForPinnedDevice
    /// Keeping is on with no pin chosen yet.
    case noPinSelected

    static func status(
        keepingEnabled: Bool,
        pinnedUID: String?,
        currentUID: String?,
        availableUIDs: Set<String>
    ) -> DirectionStatus {
        guard keepingEnabled else { return .notKeeping }
        guard let pinnedUID else { return .noPinSelected }
        guard availableUIDs.contains(pinnedUID) else { return .waitingForPinnedDevice }
        return currentUID == pinnedUID ? .kept : .restoring
    }
}
