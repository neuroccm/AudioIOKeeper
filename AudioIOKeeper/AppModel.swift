import Foundation
import Observation
import OSLog

/// One entry in the visible activity log, so the user can always see exactly
/// what the keeper did and when — an app that overrides system behavior must
/// never act invisibly.
struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let message: String
}

/// The app's single source of truth.
///
/// Owns the hardware worker, mirrors the current system state, holds the
/// user's pins, and enforces them: whenever the system default drifts from a
/// pin while keeping is enabled (AirPods removed, Continuity camera/mic
/// appearing, …) the pin is restored. Changes made *in this app* update the
/// pin instead, so the keeper never fights its own user.
///
/// All Core Audio work happens on the worker's serial queue; this model
/// only ever awaits snapshots, so a stalled HAL call cannot freeze the UI.
/// If something else keeps switching a default back, per-direction
/// throttling (`RestoreThrottle`) rate-limits restores with growing
/// cooldowns and surfaces the conflict instead of thrashing the audio
/// subsystem switch-for-switch.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [AudioDevice] = []
    private(set) var activityLog: [ActivityEntry] = []
    var launchAtLogin: Bool = LoginItemManager.isEnabled {
        didSet { LoginItemManager.setEnabled(launchAtLogin) }
    }

    @ObservationIgnored private let worker: any AudioHardwareWorking
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "AppModel")

    @ObservationIgnored private var currentDefaultUID: [AudioDirection: String?] = [:]
    @ObservationIgnored private var throttles: [AudioDirection: RestoreThrottle] = [:]
    /// Newest worker sequence applied to this model's state. Snapshots that
    /// resolve out of order (a slow read finishing after a newer write) are
    /// rejected so stale data cannot overwrite fresher state.
    @ObservationIgnored private var lastAppliedSequence: UInt64 = 0
    @ObservationIgnored private var adoptedInitialPins = false
    @ObservationIgnored private var started = false

    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reconcilePending = false
    @ObservationIgnored private var reconcileReason = "after a system change"
    @ObservationIgnored private var retryTasks: [AudioDirection: Task<Void, Never>] = [:]
    @ObservationIgnored private var resumeTask: Task<Void, Never>?

    /// How long "Pause keeping" lasts: long enough for a call or a couple
    /// of songs on another device, short enough that forgetting about it
    /// does not leave the keeper off-duty for the day.
    static let defaultPauseDuration: TimeInterval = 15 * 60

    init(
        worker: any AudioHardwareWorking = AudioHardwareWorker(),
        settings: SettingsStore = SettingsStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.worker = worker
        self.settings = settings
        self.now = now
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        worker.start()
        pingTask = Task { @MainActor [weak self] in
            guard let pings = self?.worker.changePings else { return }
            for await _ in pings {
                self?.requestReconcile(reason: "after a system change")
            }
        }
        if let until = settings.pausedUntil(), until > now() {
            log("Keeping is paused until \(until.formatted(date: .omitted, time: .shortened))")
            scheduleResume(at: until)
        }
        requestReconcile(reason: "at launch")
    }

    /// Manually re-reads the connected devices and re-checks the pins.
    /// Core Audio normally announces hot-plug changes, but moving between
    /// docks/hubs (or waking) can occasionally leave clients with a stale
    /// picture; the rescan button forces a fresh snapshot.
    func rescanDevices() {
        log("Rescanning connected devices…")
        requestReconcile(reason: "after a manual rescan")
    }

    // MARK: - Reconcile loop

    private func requestReconcile(reason: String) {
        reconcileReason = reason
        if reconcileTask != nil {
            reconcilePending = true
            return
        }
        reconcileTask = Task { @MainActor [weak self] in
            await self?.runReconcileLoop()
        }
    }

    private func runReconcileLoop() async {
        repeat {
            reconcilePending = false
            await reconcileOnce(reason: reconcileReason)
        } while reconcilePending
        reconcileTask = nil
    }

    private func reconcileOnce(reason: String) async {
        let snapshot = await worker.snapshot()
        guard snapshot.sequence > lastAppliedSequence else { return }
        lastAppliedSequence = snapshot.sequence
        devices = snapshot.devices
        for direction in AudioDirection.allCases {
            currentDefaultUID[direction] = snapshot.defaultUID(for: direction)
        }

        if !adoptedInitialPins {
            adoptedInitialPins = true
            adoptCurrentDefaultsAsInitialPins()
        }

        // A pause whose deadline has passed ends here even if its wake-up
        // task never fired (system sleep can overrun a timer): expiry is
        // decided against the clock, the task only makes it prompt.
        if settings.pausedUntil() != nil, !isPaused {
            resumeKeeping()
        }

        for direction in AudioDirection.allCases {
            await enforcePin(for: direction, reason: reason)
        }
    }

    /// On first launch there is no pin yet. Adopting whatever the system is
    /// already using means "keep what I have" works out of the box without
    /// changing anything on the system.
    private func adoptCurrentDefaultsAsInitialPins() {
        for direction in AudioDirection.allCases where settings.pinnedUID(for: direction) == nil {
            if let uid = currentUID(for: direction),
               let device = devices.first(where: { $0.uid == uid }) {
                settings.setPin(uid: device.uid, name: device.name, for: direction)
                log("Pinned current \(direction.displayName.lowercased()) “\(device.name)”")
            }
        }
    }

    // MARK: - Enforcement

    private func enforcePin(for direction: AudioDirection, reason: String) async {
        let available = Set(devices.filter { $0.supports(direction) }.map(\.uid))
        let action = KeeperEngine.action(
            keepingEnabled: keepingEnabled(for: direction) && !isPaused,
            pinnedUID: settings.pinnedUID(for: direction),
            currentUID: currentUID(for: direction),
            availableUIDs: available
        )

        guard case .restore(let uid) = action else {
            if currentUID(for: direction) == settings.pinnedUID(for: direction),
               settings.pinnedUID(for: direction) != nil {
                throttle(for: direction).recordStableObservation(at: now())
            }
            return
        }

        switch throttle(for: direction).decision(now: now()) {
        case .cooldown(let until):
            let name = devices.first { $0.uid == uid }?.name ?? uid
            log("“\(name)” keeps being switched away — pausing \(direction.displayName.lowercased()) restores, retrying soon")
            let dir = direction.rawValue
            logger.warning("Restore of \(dir, privacy: .public) throttled until \(until, privacy: .public): conflicting writer?")
            scheduleRetry(for: direction, at: until)
        case .allow:
            throttle(for: direction).recordRestore(at: now())
            let result = await worker.setDefaultDevice(uid: uid, for: direction)
            if result.sequence > lastAppliedSequence {
                lastAppliedSequence = result.sequence
            }
            let name = devices.first { $0.uid == uid }?.name ?? uid
            if result.succeeded {
                currentDefaultUID[direction] = uid
                log("Restored \(direction.displayName.lowercased()) to “\(name)” \(reason)")
                let dir = direction.rawValue
                logger.info("Restored default \(dir, privacy: .public) to \(uid, privacy: .public) \(reason, privacy: .public)")
            } else {
                log("Could not restore \(direction.displayName.lowercased()) to “\(name)”")
            }
        }
    }

    private func scheduleRetry(for direction: AudioDirection, at date: Date) {
        retryTasks[direction]?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        retryTasks[direction] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.requestReconcile(reason: "retrying after a conflict cooldown")
        }
    }

    /// Dictionary-backed mutable access to a direction's throttle.
    private func throttle(for direction: AudioDirection) -> ThrottleRef {
        ThrottleRef(model: self, direction: direction)
    }

    /// Lightweight proxy so call sites can use mutating throttle methods.
    @MainActor
    private struct ThrottleRef {
        let model: AppModel
        let direction: AudioDirection

        func decision(now: Date) -> RestoreThrottle.Decision {
            var value = model.throttles[direction] ?? RestoreThrottle()
            defer { model.throttles[direction] = value }
            return value.decision(now: now)
        }

        func recordRestore(at date: Date) {
            var value = model.throttles[direction] ?? RestoreThrottle()
            value.recordRestore(at: date)
            model.throttles[direction] = value
        }

        func recordStableObservation(at date: Date) {
            guard var value = model.throttles[direction] else { return }
            value.recordStableObservation(at: date)
            model.throttles[direction] = value
        }
    }

    // MARK: - User actions

    /// The user picked a device in this app: it becomes the new pin and the
    /// new system default, effective immediately. The pin is stored first,
    /// so any reconcile already in flight decides against the new pin and
    /// can never restore the previous one over the user's choice.
    func selectDevice(_ device: AudioDevice, for direction: AudioDirection) {
        settings.setPin(uid: device.uid, name: device.name, for: direction)
        throttles[direction]?.reset()
        retryTasks[direction]?.cancel()
        log("Pinned \(direction.displayName.lowercased()) to “\(device.name)”")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await worker.setDefaultDevice(uid: device.uid, for: direction)
            if result.sequence > lastAppliedSequence {
                lastAppliedSequence = result.sequence
            }
            if result.succeeded {
                currentDefaultUID[direction] = device.uid
            }
            requestReconcile(reason: "after selecting a device")
        }
    }

    func setKeepingEnabled(_ enabled: Bool, for direction: AudioDirection) {
        settings.setKeepingEnabled(enabled, for: direction)
        throttles[direction]?.reset()
        retryTasks[direction]?.cancel()
        log("Keeping \(direction.displayName.lowercased()) \(enabled ? "on" : "off")")
        if enabled { requestReconcile(reason: "after enabling keeping") }
    }

    /// Pauses keeping in both directions for a while, so macOS may switch
    /// freely (AirPods in for one call) without unpinning anything.
    /// Pins, toggles, and explicit in-app selections are unaffected — a
    /// device picked here still applies immediately; only automatic
    /// restores hold off. The deadline is persisted, so relaunching
    /// mid-pause does not silently resume, and any drift during the pause
    /// is the user's own business, never counted as a conflict.
    func pauseKeeping(for duration: TimeInterval = AppModel.defaultPauseDuration) {
        let until = now().addingTimeInterval(duration)
        settings.setPausedUntil(until)
        for direction in AudioDirection.allCases {
            throttles[direction]?.reset()
            retryTasks[direction]?.cancel()
        }
        scheduleResume(at: until)
        log("Paused keeping for \(Int(duration / 60)) minutes — macOS may switch freely")
    }

    /// Ends a pause (manually, on expiry, or when the wake-up task fires)
    /// and immediately re-checks the pins, restoring any that drifted.
    func resumeKeeping() {
        guard settings.pausedUntil() != nil else { return }
        settings.setPausedUntil(nil)
        resumeTask?.cancel()
        resumeTask = nil
        for direction in AudioDirection.allCases {
            throttles[direction]?.reset()
            retryTasks[direction]?.cancel()
        }
        log("Resumed keeping")
        requestReconcile(reason: "after resuming from a pause")
    }

    private func scheduleResume(at date: Date) {
        resumeTask?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resumeKeeping()
        }
    }

    // MARK: - Derived state for the UI

    func devices(for direction: AudioDirection) -> [AudioDevice] {
        devices.filter { $0.supports(direction) }
    }

    func currentUID(for direction: AudioDirection) -> String? {
        currentDefaultUID[direction] ?? nil
    }

    func pinnedUID(for direction: AudioDirection) -> String? {
        settings.pinnedUID(for: direction)
    }

    func pinnedName(for direction: AudioDirection) -> String? {
        devices.first { $0.uid == pinnedUID(for: direction) }?.name
            ?? settings.pinnedName(for: direction)
    }

    func keepingEnabled(for direction: AudioDirection) -> Bool {
        settings.keepingEnabled(for: direction)
    }

    /// The persisted pause deadline, past or future; `isPaused` gives it
    /// meaning against the clock.
    var pausedUntil: Date? { settings.pausedUntil() }

    var isPaused: Bool {
        guard let until = settings.pausedUntil() else { return false }
        return until > now()
    }

    func isConflicting(for direction: AudioDirection) -> Bool {
        throttles[direction]?.isConflicting(now: now()) ?? false
    }

    /// Bumped whenever persisted settings change, so SwiftUI views that read
    /// settings through this model refresh.
    private(set) var settingsRevision = 0

    func status(for direction: AudioDirection) -> DirectionStatus {
        _ = settingsRevision
        return DirectionStatus.status(
            keepingEnabled: keepingEnabled(for: direction),
            pinnedUID: pinnedUID(for: direction),
            currentUID: currentUID(for: direction),
            availableUIDs: Set(devices(for: direction).map(\.uid)),
            inConflict: isConflicting(for: direction),
            isPaused: isPaused
        )
    }

    /// Overall health for the menu bar icon.
    var isAnyDirectionWaiting: Bool {
        AudioDirection.allCases.contains {
            let state = status(for: $0)
            return state == .waitingForPinnedDevice || state == .conflicted
        }
    }

    var isKeepingAnything: Bool {
        AudioDirection.allCases.contains { keepingEnabled(for: $0) }
    }

    /// `isKeepingAnything` with an active pause netted out, for the menu
    /// bar icon: a paused keeper is off-duty and should look it.
    var isActivelyKeepingAnything: Bool {
        isKeepingAnything && !isPaused
    }

    // MARK: - Activity log

    private func log(_ message: String) {
        settingsRevision += 1
        activityLog.insert(ActivityEntry(date: Date(), message: message), at: 0)
        if activityLog.count > 12 { activityLog.removeLast(activityLog.count - 12) }
        logger.info("\(message, privacy: .public)")
    }
}
