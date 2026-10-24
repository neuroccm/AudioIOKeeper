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
/// Owns the hardware client, mirrors the current system state, holds the
/// user's pins, and enforces them: whenever the system default drifts from a
/// pin while keeping is enabled (AirPods removed, Continuity camera/mic
/// appearing, …) the pin is restored. Changes made *in this app* update the
/// pin instead, so the keeper never fights its own user.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [AudioDevice] = []
    private(set) var activityLog: [ActivityEntry] = []
    var launchAtLogin: Bool = LoginItemManager.isEnabled {
        didSet { LoginItemManager.setEnabled(launchAtLogin) }
    }

    @ObservationIgnored private let client: any AudioHardwareClient
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "AppModel")
    @ObservationIgnored private var currentDefaultUID: [AudioDirection: String?] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(
        client: any AudioHardwareClient = CoreAudioHardwareClient(),
        settings: SettingsStore = SettingsStore()
    ) {
        self.client = client
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        client.addChangeListener { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }

        refresh()
        adoptCurrentDefaultsAsInitialPins()
        enforcePins(reason: "at launch")
    }

    /// Coalesces bursts of Core Audio notifications (a single hot-plug can
    /// fire several) into one refresh on the next run-loop turn.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.enforcePins(reason: "after a system change")
        }
    }

    private func refresh() {
        devices = client.allDevices()
        for direction in AudioDirection.allCases {
            currentDefaultUID[direction] = client.defaultDeviceUID(for: direction)
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

    private func enforcePins(reason: String) {
        for direction in AudioDirection.allCases {
            let available = Set(devices.filter { $0.supports(direction) }.map(\.uid))
            let action = KeeperEngine.action(
                keepingEnabled: keepingEnabled(for: direction),
                pinnedUID: settings.pinnedUID(for: direction),
                currentUID: currentUID(for: direction),
                availableUIDs: available
            )
            if case .restore(let uid) = action {
                let name = devices.first { $0.uid == uid }?.name ?? uid
                if client.setDefaultDevice(uid: uid, for: direction) {
                    currentDefaultUID[direction] = uid
                    log("Restored \(direction.displayName.lowercased()) to “\(name)” \(reason)")
                    let dir = direction.rawValue
                    logger.info(
                        "Restored default \(dir, privacy: .public) to \(uid, privacy: .public) \(reason, privacy: .public)"
                    )
                } else {
                    log("Could not restore \(direction.displayName.lowercased()) to “\(name)”")
                }
            }
        }
    }

    // MARK: - User actions

    /// The user picked a device in this app: it becomes the new pin and the
    /// new system default, effective immediately.
    func selectDevice(_ device: AudioDevice, for direction: AudioDirection) {
        settings.setPin(uid: device.uid, name: device.name, for: direction)
        if client.setDefaultDevice(uid: device.uid, for: direction) {
            currentDefaultUID[direction] = device.uid
        }
        log("Pinned \(direction.displayName.lowercased()) to “\(device.name)”")
    }

    func setKeepingEnabled(_ enabled: Bool, for direction: AudioDirection) {
        settings.setKeepingEnabled(enabled, for: direction)
        log("Keeping \(direction.displayName.lowercased()) \(enabled ? "on" : "off")")
        if enabled { enforcePins(reason: "after enabling keeping") }
    }

    // MARK: - Derived state for the UI

    func devices(for direction: AudioDirection) -> [AudioDevice] {
        devices.filter { $0.supports(direction) }
    }

    func currentUID(for direction: AudioDirection) -> String? {
        currentDefaultUID[direction] ?? nil
    }

    func currentDevice(for direction: AudioDirection) -> AudioDevice? {
        devices.first { $0.uid == currentUID(for: direction) }
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

    /// Bumped whenever persisted settings change, so SwiftUI views that read
    /// settings through this model refresh.
    private(set) var settingsRevision = 0

    func status(for direction: AudioDirection) -> DirectionStatus {
        _ = settingsRevision
        return DirectionStatus.status(
            keepingEnabled: keepingEnabled(for: direction),
            pinnedUID: pinnedUID(for: direction),
            currentUID: currentUID(for: direction),
            availableUIDs: Set(devices(for: direction).map(\.uid))
        )
    }

    /// Overall health for the menu bar icon.
    var isAnyDirectionWaiting: Bool {
        AudioDirection.allCases.contains { status(for: $0) == .waitingForPinnedDevice }
    }

    var isKeepingAnything: Bool {
        AudioDirection.allCases.contains { keepingEnabled(for: $0) }
    }

    // MARK: - Activity log

    private func log(_ message: String) {
        settingsRevision += 1
        activityLog.insert(ActivityEntry(date: Date(), message: message), at: 0)
        if activityLog.count > 12 { activityLog.removeLast(activityLog.count - 12) }
        logger.info("\(message, privacy: .public)")
    }
}
