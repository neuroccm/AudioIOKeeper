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
        static let lockSystemOutput = "lockSystemOutputEnabled"
        static let didAdoptInitialPins = "didAdoptInitialPins"
        static let didAdoptInitialInputPin = "didAdoptInitialInputPin"
        static let didAdoptInitialOutputPin = "didAdoptInitialOutputPin"
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

    /// Whether locking output also keeps system alert/sound-effect output
    /// (`kAudioHardwarePropertyDefaultSystemOutputDevice`) on the pinned output.
    /// Defaults to on so macOS chimes and dictation cues follow the pinned output.
    func lockSystemOutputEnabled() -> Bool {
        defaults.object(forKey: Key.lockSystemOutput) as? Bool ?? true
    }

    func setLockSystemOutputEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.lockSystemOutput)
    }

    /// Legacy global marker read as fallback for pre-1.3 installs.
    func didAdoptInitialPins() -> Bool {
        defaults.bool(forKey: Key.didAdoptInitialPins)
    }

    /// Per-direction adoption: a direction whose default was unreadable on
    /// the first snapshot stays pending and can still be adopted later,
    /// while a completed direction is never adopted again. Falls back to
    /// the legacy global marker so installs that set it stay settled.
    func didAdoptInitialPin(for direction: AudioDirection) -> Bool {
        let key = direction == .input ? Key.didAdoptInitialInputPin : Key.didAdoptInitialOutputPin
        return defaults.object(forKey: key) as? Bool ?? didAdoptInitialPins()
    }

    func setDidAdoptInitialPin(for direction: AudioDirection) {
        let key = direction == .input ? Key.didAdoptInitialInputPin : Key.didAdoptInitialOutputPin
        defaults.set(true, forKey: key)
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

// MARK: - AppModel settings & pause state

extension AppModel {

    func loadPersistedState() {
        for direction in AudioDirection.allCases {
            keepingFlags[direction] = settings.keepingEnabled(for: direction)
            if let uid = settings.pinnedUID(for: direction) { pinnedUIDs[direction] = uid }
            if let name = settings.pinnedName(for: direction) { pinnedNames[direction] = name }
        }
        pausedUntil = settings.pausedUntil()
        lockSystemOutput = settings.lockSystemOutputEnabled()
    }

    func storePin(uid: String?, name: String?, for direction: AudioDirection) {
        settings.setPin(uid: uid, name: name, for: direction)
        if uid != nil {
            settings.setDidAdoptInitialPin(for: direction)
        }
        pinnedUIDs[direction] = uid
        pinnedNames[direction] = uid == nil ? nil : name
    }

    func storeKeeping(_ enabled: Bool, for direction: AudioDirection) {
        settings.setKeepingEnabled(enabled, for: direction)
        keepingFlags[direction] = enabled
    }

    func storePausedUntil(_ date: Date?) {
        settings.setPausedUntil(date)
        pausedUntil = date
    }

    func setLockSystemOutput(_ enabled: Bool) {
        guard lockSystemOutput != enabled else { return }
        lockSystemOutput = enabled
        settings.setLockSystemOutputEnabled(enabled)
        systemOutputThrottle.reset()
        log("System sound effects lock \(enabled ? "on" : "off")")
        if enabled { requestReconcile(reason: "after enabling system sound lock") }
    }

    /// Temporarily unlocks both pins; only automatic restores hold off.
    func pauseKeeping(for duration: TimeInterval = AppModel.defaultPauseDuration) {
        guard duration > 0 else { return }
        let until = now().addingTimeInterval(duration)
        storePausedUntil(until)
        cancelActiveRestoresAndResetThrottles()
        scheduleResume(at: until)
        log("Paused keeping for \(Self.formatDuration(duration)) — macOS may switch freely")
    }

    /// Ends a temporary unlock and re-checks the pins at once.
    func resumeKeeping() {
        guard pausedUntil != nil else { return }
        clearPause(logMessage: "Resumed keeping")
        requestReconcile(reason: "after resuming from a pause")
    }

    func scheduleResume(at date: Date) {
        resumeTask?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resumeKeeping()
        }
    }

    func clearPause(logMessage: String) {
        storePausedUntil(nil)
        resumeTask?.cancel()
        resumeTask = nil
        for direction in AudioDirection.allCases { resetThrottle(for: direction) }
        systemOutputThrottle.reset()
        log(logMessage)
    }

    /// Forces a fresh hardware snapshot (docks/hubs can leave a stale one).
    func rescanDevices() {
        log("Rescanning connected devices…")
        requestReconcile(reason: "after a manual rescan")
    }

    /// Refreshes hardware state silently when the user opens the popover or Settings.
    func refreshOnMenuOpen() {
        guard started else { return }
        requestReconcile(reason: "when opening the menu")
    }

    /// Triggered by `AppDelegate` on `NSWorkspace.didWakeNotification`.
    func handleSystemWake() {
        requestReconcile(reason: "after waking from sleep")
        wakeFollowUpTask?.cancel()
        wakeFollowUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.wakeFollowUpDelay))
            guard !Task.isCancelled else { return }
            self?.requestReconcile(reason: "after waking from sleep")
        }
    }

    /// First-launch adoption, per direction. An unreadable default stays
    /// pending; disabled keeping completes without a pin. A completed
    /// direction is never re-adopted (unpins stick).
    func adoptCurrentDefaultsAsInitialPins() {
        for direction in AudioDirection.allCases where !settings.didAdoptInitialPin(for: direction) {
            if pinnedUID(for: direction) != nil || !keepingEnabled(for: direction) {
                settings.setDidAdoptInitialPin(for: direction)
                continue
            }
            guard let uid = currentUID(for: direction),
                  let device = devices.first(where: { $0.uid == uid && $0.supports(direction) }) else {
                continue
            }
            let label = displayName(for: device, direction: direction)
            storePin(uid: device.uid, name: label, for: direction)
            settings.setDidAdoptInitialPin(for: direction)
            log("Pinned current \(direction.displayName.lowercased()) “\(label)”")
        }
    }
}
