import Foundation
import Observation
import OSLog

/// The app's single source of truth: owns the worker, mirrors system state,
/// holds the pins, and restores a pin whenever the system default drifts from
/// it. In-app changes update the pin instead, so the keeper never fights its
/// own user. All Core Audio work stays on the worker's queue; a competing
/// switcher is throttled (`RestoreThrottle`), not fought.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [AudioDevice] = []
    private(set) var currentDefaultUID: [AudioDirection: String?] = [:]
    private(set) var currentSystemOutputUID: String?
    var pinnedUIDs: [AudioDirection: String] = [:]
    var pinnedNames: [AudioDirection: String] = [:]
    var keepingFlags: [AudioDirection: Bool] = [:]
    var pausedUntil: Date?
    var lockSystemOutput = false
    private(set) var throttles: [AudioDirection: RestoreThrottle] = [:]
    private(set) var activityLog: [ActivityEntry] = []
    var launchAtLogin = false
    var loginItemNeedsApproval = false
    var loginItemError: String?

    @ObservationIgnored private let worker: any AudioHardwareWorking
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let loginItem: any LoginItemManaging
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "AppModel")
    @ObservationIgnored private let deinitBag = CancellationBag()

    @ObservationIgnored private var lastAppliedSequence: UInt64 = 0
    @ObservationIgnored var started = false
    @ObservationIgnored var systemOutputThrottle = RestoreThrottle()

    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reconcilePending = false
    @ObservationIgnored private var reconcileReason = "after a system change"
    @ObservationIgnored private var retryTasks: [AudioDirection: Task<Void, Never>] = [:]
    @ObservationIgnored private var selectionTasks: [AudioDirection: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var restoreTasks: [AudioDirection: (id: UUID, task: Task<HardwareWriteResult, Never>)] = [:]
    @ObservationIgnored private var systemOutputTask: Task<HardwareWriteResult, Never>?
    @ObservationIgnored var resumeTask: Task<Void, Never>?
    @ObservationIgnored var wakeFollowUpTask: Task<Void, Never>?

    /// How long the Settings "temporarily unlock" lasts.
    static let defaultPauseDuration: TimeInterval = 15 * 60
    /// Delay for a second post-wake scan so slow DisplayPort/dock devices are caught.
    static let wakeFollowUpDelay: TimeInterval = 1.5

    init(
        worker: any AudioHardwareWorking = AudioHardwareWorker(),
        settings: SettingsStore = SettingsStore(),
        loginItem: any LoginItemManaging = SystemLoginItemManager(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.worker = worker
        self.settings = settings
        self.loginItem = loginItem
        self.now = now
        loadPersistedState()
        applyLoginItemStatus(loginItem.status)
    }

    deinit { deinitBag.cancel() }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        worker.start()

        let pings = worker.changePings
        let task = Task { @MainActor [weak self] in
            for await _ in pings {
                guard !Task.isCancelled else { break }
                self?.requestReconcile(reason: "after a system change")
            }
        }
        pingTask = task
        deinitBag.set { task.cancel() }

        if let until = pausedUntil, until > now() {
            log("Keeping is paused until \(until.formatted(date: .omitted, time: .shortened))")
            scheduleResume(at: until)
        }
        requestReconcile(reason: "at launch")
    }

    /// Cancels all background tasks owned by the model (called on quit and in tests).
    func stop() {
        started = false
        deinitBag.cancel()
        [pingTask, reconcileTask, resumeTask, wakeFollowUpTask].forEach { $0?.cancel() }
        systemOutputTask?.cancel()
        pingTask = nil
        reconcileTask = nil
        resumeTask = nil
        wakeFollowUpTask = nil
        systemOutputTask = nil
        for direction in AudioDirection.allCases {
            retryTasks.removeValue(forKey: direction)?.cancel()
            selectionTasks.removeValue(forKey: direction)?.task.cancel()
            restoreTasks.removeValue(forKey: direction)?.task.cancel()
        }
    }

    // MARK: - User actions

    /// Pins and uses a device right away. The pin *is* the lock, so pinning
    /// turns keeping on (and ends any temporary pause) before any reconcile runs.
    func selectDevice(_ device: AudioDevice, for direction: AudioDirection) {
        let label = displayName(for: device, direction: direction)
        if isPaused { clearPause(logMessage: "Resumed keeping after pinning “\(label)”") }
        storePin(uid: device.uid, name: label, for: direction)
        storeKeeping(true, for: direction)
        resetThrottle(for: direction)
        _ = cancelWrites(for: direction)
        log("Pinned \(direction.displayName.lowercased()) to “\(label)”")

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if selectionTasks[direction]?.id == token { selectionTasks.removeValue(forKey: direction) }
            }
            let result = await worker.setDefaultDevice(uid: device.uid, for: direction)
            guard !Task.isCancelled, !result.wasSkipped else { return }
            if result.sequence > lastAppliedSequence { lastAppliedSequence = result.sequence }
            if result.succeeded, pinnedUID(for: direction) == device.uid {
                currentDefaultUID[direction] = device.uid
                if direction == .output, lockSystemOutput, device.canBeDefaultSystemOutput {
                    await syncSystemOutputWrite(uid: device.uid)
                }
            } else if !result.succeeded {
                log("Could not switch \(direction.displayName.lowercased()) to “\(label)” — will retry")
            }
            if selectionTasks[direction]?.id == token { selectionTasks.removeValue(forKey: direction) }
            requestReconcile(reason: "after selecting a device")
        }
        selectionTasks[direction] = (token, task)
    }

    /// Pin-button action: locks an unpinned (or paused) device, unlocks an actively locked one.
    func togglePin(_ device: AudioDevice, for direction: AudioDirection) {
        let isActivelyLocked = pinnedUID(for: direction) == device.uid && keepingEnabled(for: direction) && !isPaused
        if isActivelyLocked { unpinDevice(for: direction) } else { selectDevice(device, for: direction) }
    }

    /// Unlocks without switching: the device in use stays in use.
    func unpinDevice(for direction: AudioDirection) {
        let hadPendingWrite = cancelWrites(for: direction)
        let hadPin = pinnedUID(for: direction) != nil
        guard hadPin || keepingEnabled(for: direction) else { return }

        let name = pinnedName(for: direction) ?? "pinned device"
        storePin(uid: nil, name: nil, for: direction)
        storeKeeping(false, for: direction)
        settings.setDidAdoptInitialPin(for: direction)
        resetThrottle(for: direction)
        if hadPin { log("Unpinned \(direction.displayName.lowercased()) “\(name)” — macOS may switch freely") }
        if hadPendingWrite { requestReconcile(reason: "after unpinning") }
    }

    func setKeepingEnabled(_ enabled: Bool, for direction: AudioDirection) {
        if !enabled { _ = cancelWrites(for: direction) }
        storeKeeping(enabled, for: direction)
        resetThrottle(for: direction)
        log("Keeping \(direction.displayName.lowercased()) \(enabled ? "on" : "off")")
        if enabled { requestReconcile(reason: "after enabling keeping") }
    }

    func retryDirection(_ direction: AudioDirection) {
        resetThrottle(for: direction)
        requestReconcile(reason: "after a manual retry")
    }

    // MARK: - Internal coordination hooks

    func requestReconcile(reason: String) {
        reconcileReason = reason
        if reconcileTask != nil {
            reconcilePending = true
            return
        }
        reconcileTask = Task { @MainActor [weak self] in await self?.runReconcileLoop() }
    }

    func cancelActiveRestoresAndResetThrottles() {
        for direction in AudioDirection.allCases {
            restoreTasks.removeValue(forKey: direction)?.task.cancel()
            resetThrottle(for: direction)
        }
        systemOutputTask?.cancel()
        systemOutputTask = nil
        systemOutputThrottle.reset()
    }

    func resetThrottle(for direction: AudioDirection) {
        throttles[direction]?.reset()
        if direction == .output { systemOutputThrottle.reset() }
        retryTasks.removeValue(forKey: direction)?.cancel()
    }

    func log(_ message: String) {
        activityLog.insert(ActivityEntry(date: now(), message: message), at: 0)
        if activityLog.count > 12 { activityLog.removeLast(activityLog.count - 12) }
        logger.info("\(message, privacy: .public)")
    }
}

// MARK: - Reconcile & enforcement

private extension AppModel {

    func runReconcileLoop() async {
        repeat {
            reconcilePending = false
            await reconcileOnce(reason: reconcileReason)
        } while reconcilePending && !Task.isCancelled
        reconcileTask = nil
    }

    func reconcileOnce(reason: String) async {
        let snapshot = await worker.snapshot()
        guard !Task.isCancelled, snapshot.sequence > lastAppliedSequence else { return }
        lastAppliedSequence = snapshot.sequence
        if devices != snapshot.devices { devices = snapshot.devices }
        for direction in AudioDirection.allCases {
            let uid = snapshot.defaultUID(for: direction)
            if currentDefaultUID[direction] ?? nil != uid { currentDefaultUID[direction] = uid }
        }
        if currentSystemOutputUID != snapshot.defaultSystemOutputUID {
            currentSystemOutputUID = snapshot.defaultSystemOutputUID
        }

        adoptCurrentDefaultsAsInitialPins()
        if pausedUntil != nil, !isPaused { clearPause(logMessage: "Resumed keeping") }

        for direction in AudioDirection.allCases { await enforcePin(for: direction, reason: reason) }
        await enforceSystemOutput(reason: reason)
    }

    func enforcePin(for direction: AudioDirection, reason: String) async {
        guard selectionTasks[direction] == nil else { return }

        let action = KeeperEngine.action(
            keepingEnabled: keepingEnabled(for: direction) && !isPaused,
            pinnedUID: pinnedUID(for: direction),
            currentUID: currentUID(for: direction),
            availableUIDs: Set(devices(for: direction).map(\.uid))
        )
        guard case .restore(let uid) = action else {
            if currentUID(for: direction) == pinnedUID(for: direction), pinnedUID(for: direction) != nil {
                throttles[direction]?.recordStableObservation(at: now())
            }
            return
        }

        let priorCooldown = throttles[direction]?.cooldownUntil
        var throttle = throttles[direction] ?? RestoreThrottle()
        let decision = throttle.decision(now: now())
        throttles[direction] = throttle

        switch decision {
        case .cooldown(let until):
            guard until != priorCooldown || retryTasks[direction] == nil else { return }
            let name = pinnedName(for: direction) ?? uid
            let dir = direction.displayName.lowercased()
            log("“\(name)” keeps being switched away — pausing \(dir) restores, retrying soon")
            let rawDir = direction.rawValue
            logger.warning("Restore of \(rawDir, privacy: .public) throttled until \(until, privacy: .public)")
            scheduleRetry(for: direction, at: until)
        case .allow:
            await performRestore(uid: uid, for: direction, reason: reason)
        }
    }

    func performRestore(uid: String, for direction: AudioDirection, reason: String) async {
        var throttle = throttles[direction] ?? RestoreThrottle()
        throttle.recordRestore(at: now())
        throttles[direction] = throttle

        let token = UUID()
        let task = Task { @MainActor [worker] in await worker.setDefaultDevice(uid: uid, for: direction) }
        restoreTasks[direction]?.task.cancel()
        restoreTasks[direction] = (token, task)
        let result = await task.value
        if restoreTasks[direction]?.id == token { restoreTasks.removeValue(forKey: direction) }
        guard !task.isCancelled, !result.wasSkipped else { return }

        if result.sequence > lastAppliedSequence { lastAppliedSequence = result.sequence }
        let name = pinnedName(for: direction) ?? uid
        let dir = direction.displayName.lowercased()
        if result.succeeded {
            if pinnedUID(for: direction) == uid, keepingEnabled(for: direction), !isPaused {
                currentDefaultUID[direction] = uid
            }
            log("Restored \(dir) to “\(name)” \(reason)")
        } else {
            log("Could not restore \(dir) to “\(name)” — will retry")
            let current = now()
            var nextThrottle = throttles[direction] ?? RestoreThrottle()
            if nextThrottle.isConflicting(now: current),
               case .cooldown(let until) = nextThrottle.decision(now: current) {
                throttles[direction] = nextThrottle
                scheduleRetry(for: direction, at: until)
            } else {
                scheduleRetry(for: direction, at: current.addingTimeInterval(RestoreThrottle.failureRetryDelay))
            }
        }
    }

    func enforceSystemOutput(reason: String) async {
        guard lockSystemOutput, keepingEnabled(for: .output), !isPaused,
              selectionTasks[.output] == nil, restoreTasks[.output] == nil,
              let uid = pinnedUID(for: .output),
              let device = devices.first(where: { $0.uid == uid }),
              device.canBeDefaultSystemOutput,
              let currentSys = currentSystemOutputUID else { return }

        if currentSys == uid {
            systemOutputThrottle.recordStableObservation(at: now())
            return
        }
        switch systemOutputThrottle.decision(now: now()) {
        case .cooldown(let until):
            if retryTasks[.output] == nil { scheduleRetry(for: .output, at: until) }
        case .allow:
            systemOutputThrottle.recordRestore(at: now())
            let label = displayName(for: device, direction: .output)
            if await syncSystemOutputWrite(uid: uid) {
                log("Restored system sound effects to “\(label)” \(reason)")
            } else if retryTasks[.output] == nil {
                scheduleRetry(for: .output, at: now().addingTimeInterval(RestoreThrottle.failureRetryDelay))
            }
        }
    }

    @discardableResult
    func syncSystemOutputWrite(uid: String) async -> Bool {
        systemOutputTask?.cancel()
        let task = Task { @MainActor [worker] in await worker.setDefaultSystemOutputDevice(uid: uid) }
        systemOutputTask = task
        let result = await task.value
        guard !task.isCancelled, !result.wasSkipped else { return false }
        if result.sequence > lastAppliedSequence { lastAppliedSequence = result.sequence }
        if result.succeeded { currentSystemOutputUID = uid }
        return result.succeeded
    }

    func scheduleRetry(for direction: AudioDirection, at date: Date) {
        retryTasks[direction]?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        retryTasks[direction] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryTasks.removeValue(forKey: direction)
            self?.requestReconcile(reason: "retrying after a conflict cooldown")
        }
    }

    func cancelWrites(for direction: AudioDirection) -> Bool {
        let selection = selectionTasks.removeValue(forKey: direction)
        selection?.task.cancel()
        let restore = restoreTasks.removeValue(forKey: direction)
        restore?.task.cancel()
        if direction == .output {
            systemOutputTask?.cancel()
            systemOutputTask = nil
        }
        return selection != nil || restore != nil
    }
}
