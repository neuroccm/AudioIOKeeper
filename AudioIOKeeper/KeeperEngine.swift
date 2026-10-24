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

/// Per-direction gate that stops restore thrashing when something else keeps
/// switching the default back (another utility, an automation, hardware
/// policy). Without a stop condition, two writers can trigger each other
/// forever — each restore fires a change notification the other side answers.
///
/// Policy: a small budget of immediate restores per rolling window covers
/// ordinary one-off switches (AirPods out, iPhone mic appearing). Beyond the
/// budget, restores are held back by exponentially growing cooldowns, capped
/// so the keeper still retries at a controlled rate. A sustained quiet
/// period with the pin in place resets everything. Pure value type with an
/// injected clock so the whole policy is unit-testable.
struct RestoreThrottle: Equatable, Sendable {

    enum Decision: Equatable, Sendable {
        /// Restore now.
        case allow
        /// Too many recent restores; do not restore before this date.
        case cooldown(until: Date)
    }

    /// Restores allowed immediately within `window` before cooldowns apply.
    static let immediateBudget = 3
    /// Rolling window over which the budget is counted, in seconds.
    static let window: TimeInterval = 60
    /// First cooldown once the budget is exhausted, in seconds.
    static let baseCooldown: TimeInterval = 2
    /// Cooldowns never grow beyond this, in seconds.
    static let maxCooldown: TimeInterval = 60
    /// Pin continuously in place this long clears the history, in seconds.
    static let quietReset: TimeInterval = 60

    private(set) var restoreTimes: [Date] = []
    private(set) var cooldownUntil: Date?

    /// True while repeated drift indicates something is actively fighting
    /// the keeper over this direction.
    func isConflicting(now: Date) -> Bool {
        recentCount(now: now) >= Self.immediateBudget
    }

    /// Asks whether a restore may happen at `now`. Calling this when the
    /// budget is exhausted arms the next cooldown; record every restore
    /// actually performed via `recordRestore(at:)`.
    mutating func decision(now: Date) -> Decision {
        prune(now: now)
        if let cooldownUntil {
            if now < cooldownUntil {
                return .cooldown(until: cooldownUntil)
            }
            // Cooldown served: allow a single retry. Recording it pushes
            // the count up, so the next decision arms a longer cooldown.
            self.cooldownUntil = nil
            return .allow
        }
        if restoreTimes.count < Self.immediateBudget {
            return .allow
        }
        let overBudget = restoreTimes.count - Self.immediateBudget
        let duration = min(Self.maxCooldown, Self.baseCooldown * pow(2.0, Double(overBudget)))
        let until = now.addingTimeInterval(duration)
        cooldownUntil = until
        return .cooldown(until: until)
    }

    mutating func recordRestore(at now: Date) {
        prune(now: now)
        restoreTimes.append(now)
    }

    /// Called when the pinned device is observed as the current default.
    /// After a full quiet period with no restores, history is forgotten so
    /// an old conflict does not penalize a future one-off switch.
    mutating func recordStableObservation(at now: Date) {
        guard let last = restoreTimes.last else {
            cooldownUntil = nil
            return
        }
        if now.timeIntervalSince(last) >= Self.quietReset {
            restoreTimes.removeAll()
            cooldownUntil = nil
        }
    }

    /// Forget everything, e.g. when the user picks a different pin or
    /// toggles keeping — a deliberate user change is not a conflict.
    mutating func reset() {
        restoreTimes.removeAll()
        cooldownUntil = nil
    }

    private func recentCount(now: Date) -> Int {
        restoreTimes.count(where: { now.timeIntervalSince($0) < Self.window })
    }

    private mutating func prune(now: Date) {
        restoreTimes.removeAll { now.timeIntervalSince($0) >= Self.window }
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
    /// Something else keeps switching the default back; restores are being
    /// rate-limited instead of fighting it switch-for-switch.
    case conflicted
    /// Keeping is on but the pinned device is disconnected right now.
    case waitingForPinnedDevice
    /// Keeping is on with no pin chosen yet.
    case noPinSelected

    static func status(
        keepingEnabled: Bool,
        pinnedUID: String?,
        currentUID: String?,
        availableUIDs: Set<String>,
        inConflict: Bool = false
    ) -> DirectionStatus {
        guard keepingEnabled else { return .notKeeping }
        guard let pinnedUID else { return .noPinSelected }
        guard availableUIDs.contains(pinnedUID) else { return .waitingForPinnedDevice }
        if currentUID == pinnedUID { return .kept }
        return inConflict ? .conflicted : .restoring
    }
}
