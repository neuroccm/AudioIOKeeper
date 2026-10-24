import Foundation

/// Typed, testable access to the app's persisted settings.
///
/// Pins are stored as device UIDs so they stay meaningful across reboots,
/// reconnects, and Core Audio id reassignment.
///
/// `@unchecked Sendable` is sound here: the only stored property is a
/// `UserDefaults`, which Apple documents as thread-safe even though the type
/// is not marked `Sendable` in the SDK.
struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let keepInput = "keepInputEnabled"
        static let keepOutput = "keepOutputEnabled"
        static let pinnedInputUID = "pinnedInputDeviceUID"
        static let pinnedOutputUID = "pinnedOutputDeviceUID"
        static let pinnedInputName = "pinnedInputDeviceName"
        static let pinnedOutputName = "pinnedOutputDeviceName"
        static let pausedUntil = "keepingPausedUntil"
    }

    func keepingEnabled(for direction: AudioDirection) -> Bool {
        // Keeping is on by default: that is the whole point of the app.
        switch direction {
        case .input: defaults.object(forKey: Key.keepInput) as? Bool ?? true
        case .output: defaults.object(forKey: Key.keepOutput) as? Bool ?? true
        }
    }

    func setKeepingEnabled(_ enabled: Bool, for direction: AudioDirection) {
        defaults.set(enabled, forKey: direction == .input ? Key.keepInput : Key.keepOutput)
    }

    func pinnedUID(for direction: AudioDirection) -> String? {
        defaults.string(forKey: direction == .input ? Key.pinnedInputUID : Key.pinnedOutputUID)
    }

    /// Last known display name for the pin, kept so the UI can still name a
    /// pinned device while it is disconnected.
    func pinnedName(for direction: AudioDirection) -> String? {
        defaults.string(forKey: direction == .input ? Key.pinnedInputName : Key.pinnedOutputName)
    }

    /// Deadline until which keeping is paused, if a pause is set. Persisted
    /// so relaunching mid-pause does not silently resume enforcement; an
    /// expired deadline is reported as-is and interpreted by the caller.
    func pausedUntil() -> Date? {
        guard let stored = defaults.object(forKey: Key.pausedUntil) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: stored)
    }

    func setPausedUntil(_ date: Date?) {
        if let date {
            defaults.set(date.timeIntervalSinceReferenceDate, forKey: Key.pausedUntil)
        } else {
            defaults.removeObject(forKey: Key.pausedUntil)
        }
    }

    func setPin(uid: String?, name: String?, for direction: AudioDirection) {
        let uidKey = direction == .input ? Key.pinnedInputUID : Key.pinnedOutputUID
        let nameKey = direction == .input ? Key.pinnedInputName : Key.pinnedOutputName
        if let uid {
            defaults.set(uid, forKey: uidKey)
            defaults.set(name, forKey: nameKey)
        } else {
            defaults.removeObject(forKey: uidKey)
            defaults.removeObject(forKey: nameKey)
        }
    }
}
