import XCTest
@testable import AudioIOKeeper

/// Controllable clock for throttle tests.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// In-memory fake of the hardware worker.
///
/// Faithfully models two real HAL behaviors the previous fake missed:
/// the app's own default-device writes generate change notifications, and
/// a competing writer can switch the default again right after a restore.
final class FakeAudioHardwareWorker: AudioHardwareWorking, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioDevice] = []
    private var _defaults: [AudioDirection: String?] = [:]
    private var sequence: UInt64 = 0
    private var _setDefaultCalls: [(uid: String, direction: AudioDirection)] = []

    /// Simulates another component reasserting its own default after every
    /// successful app write of the pinned UID (direction → rival UID).
    var competitor: [AudioDirection: String] = [:]

    let changePings: AsyncStream<Void>
    private let pingContinuation: AsyncStream<Void>.Continuation

    /// When set, the next snapshot (already captured) is held until released.
    private var snapshotGate: CheckedContinuation<Void, Never>?
    private var holdNextSnapshot = false

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        self.changePings = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.pingContinuation = continuation
    }

    var devices: [AudioDevice] {
        get { locked { _devices } }
        set { locked { _devices = newValue } }
    }

    var setDefaultCalls: [(uid: String, direction: AudioDirection)] {
        locked { _setDefaultCalls }
    }

    func setSystemDefault(_ uid: String?, for direction: AudioDirection) {
        locked { _defaults[direction] = uid }
    }

    func systemDefault(for direction: AudioDirection) -> String? {
        locked { _defaults[direction] ?? nil }
    }

    func ping() { pingContinuation.yield() }

    func start() {}

    func snapshot() async -> HardwareSnapshot {
        let captured = locked { () -> HardwareSnapshot in
            sequence += 1
            return HardwareSnapshot(sequence: sequence, devices: _devices, defaults: _defaults)
        }
        let shouldHold = locked { () -> Bool in
            let hold = holdNextSnapshot
            holdNextSnapshot = false
            return hold
        }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                locked { snapshotGate = continuation }
            }
        }
        return captured
    }

    func holdNextSnapshotCapture() {
        locked { holdNextSnapshot = true }
    }

    func releaseHeldSnapshot() {
        let gate = locked { () -> CheckedContinuation<Void, Never>? in
            defer { snapshotGate = nil }
            return snapshotGate
        }
        gate?.resume()
    }

    var isSnapshotHeld: Bool {
        locked { snapshotGate != nil }
    }

    func setDefaultDevice(uid: String, for direction: AudioDirection) async -> HardwareWriteResult {
        let result = locked { () -> HardwareWriteResult in
            _setDefaultCalls.append((uid, direction))
            _defaults[direction] = uid
            sequence += 1
            return HardwareWriteResult(sequence: sequence, succeeded: true)
        }
        // The real HAL notifies listeners about our own write.
        ping()
        // A competing writer answers by switching it back.
        if let rival = competitor[direction], rival != uid {
            locked { _defaults[direction] = rival }
            ping()
        }
        return result
    }

    /// Simulates macOS (or anything else) switching a default externally.
    func simulateSystemSwitch(to uid: String, for direction: AudioDirection) {
        setSystemDefault(uid, for: direction)
        ping()
    }

    func resetRecordedCalls() {
        locked { _setDefaultCalls.removeAll() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func makeDevice(uid: String, name: String, input: Bool, output: Bool) -> AudioDevice {
    AudioDevice(objectID: UInt32(abs(uid.hashValue % 10_000)), uid: uid, name: name,
                transport: .builtIn, hasInput: input, hasOutput: output, isAlive: true)
}

@MainActor
final class AppModelTests: XCTestCase {
    private var worker: FakeAudioHardwareWorker!
    private var settings: SettingsStore!
    private var clock: FakeClock!
    private var model: AppModel!
    private var suiteName: String!

    override func setUp() async throws {
        worker = FakeAudioHardwareWorker()
        clock = FakeClock()
        suiteName = "AudioIOKeeperTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)

        let speakers = makeDevice(uid: "speakers", name: "Studio Speakers", input: false, output: true)
        let airPods = makeDevice(uid: "airpods", name: "AirPods", input: true, output: true)
        let mic = makeDevice(uid: "usb-mic", name: "USB Mic", input: true, output: false)
        worker.devices = [speakers, airPods, mic]
        worker.setSystemDefault("speakers", for: .output)
        worker.setSystemDefault("usb-mic", for: .input)

        let clock = self.clock!
        model = AppModel(worker: worker, settings: settings, now: { clock.now() })
        model.start()
        try await settle { model.pinnedUID(for: .output) == "speakers" }
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// Polls until a condition holds (async reconcile work drains).
    private func settle(
        timeout: TimeInterval = 3,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Give any trailing no-op reconcile a chance to run.
        try await Task.sleep(for: .milliseconds(50))
    }

    func testFirstLaunchAdoptsCurrentDefaultsAsPins() {
        XCTAssertEqual(model.pinnedUID(for: .output), "speakers")
        XCTAssertEqual(model.pinnedUID(for: .input), "usb-mic")
        XCTAssertTrue(worker.setDefaultCalls.isEmpty, "adopting pins must not change the system")
    }

    func testSelectingDevicePinsAndAppliesIt() async throws {
        let airPods = worker.devices.first { $0.uid == "airpods" }!
        model.selectDevice(airPods, for: .output)
        XCTAssertEqual(model.pinnedUID(for: .output), "airpods")
        try await settle { model.currentUID(for: .output) == "airpods" }
        XCTAssertEqual(worker.setDefaultCalls.last?.uid, "airpods")
        XCTAssertEqual(model.currentUID(for: .output), "airpods")
    }

    /// The core promise: an automatic system switch is reverted to the pin,
    /// and the notification caused by our own restore does not loop.
    func testAutomaticSwitchIsRevertedToPinExactlyOnce() async throws {
        worker.simulateSystemSwitch(to: "airpods", for: .output)

        try await settle { model.currentUID(for: .output) == "speakers" }

        let outputWrites = worker.setDefaultCalls.filter { $0.direction == .output }
        XCTAssertEqual(outputWrites.map(\.uid), ["speakers"], "exactly one restore, no self-triggered loop")
        XCTAssertTrue(model.activityLog.contains { $0.message.contains("Restored output") })
    }

    func testAutomaticSwitchIsLeftAloneWhenKeepingOff() async throws {
        model.setKeepingEnabled(false, for: .output)
        worker.resetRecordedCalls()

        worker.simulateSystemSwitch(to: "airpods", for: .output)
        try await settle { model.currentUID(for: .output) == "airpods" }

        XCTAssertTrue(worker.setDefaultCalls.isEmpty)
    }

    /// Finding 1: a competing writer that switches the default back after
    /// every restore must not cause unbounded restore thrashing. Restores
    /// stop at the immediate budget, the direction reports a conflict, and
    /// exactly one retry is allowed after the cooldown expires.
    func testCompetingWriterIsThrottledNotFoughtForever() async throws {
        worker.competitor = [.output: "airpods"]
        worker.simulateSystemSwitch(to: "airpods", for: .output)

        try await settle(timeout: 2) { model.status(for: .output) == .conflicted }

        let writes = worker.setDefaultCalls.filter { $0.direction == .output }.map(\.uid)
        XCTAssertEqual(writes, Array(repeating: "speakers", count: RestoreThrottle.immediateBudget))
        XCTAssertEqual(model.status(for: .output), .conflicted)
        XCTAssertTrue(model.activityLog.contains { $0.message.contains("keeps being switched away") })

        // After the cooldown, one controlled retry is allowed — not a burst.
        clock.advance(by: RestoreThrottle.baseCooldown + 1)
        worker.ping()
        try await settle(timeout: 2) {
            worker!.setDefaultCalls.filter { $0.direction == .output }.count
                == RestoreThrottle.immediateBudget + 1
        }
        let afterRetry = worker.setDefaultCalls.filter { $0.direction == .output }.count
        XCTAssertEqual(afterRetry, RestoreThrottle.immediateBudget + 1)
    }

    /// Finding 2: a slow snapshot captured before the user changed the pin
    /// must be rejected when it finally arrives — its stale view must not
    /// restore the old pin over the user's newer selection.
    func testStaleSnapshotCannotOverwriteNewerUserSelection() async throws {
        worker.holdNextSnapshotCapture()
        worker.simulateSystemSwitch(to: "airpods", for: .output)
        try await settle { worker.isSnapshotHeld }

        // While the drift snapshot is in flight, the user picks AirPods.
        let airPods = worker.devices.first { $0.uid == "airpods" }!
        model.selectDevice(airPods, for: .output)
        try await settle { worker.systemDefault(for: .output) == "airpods" }

        worker.releaseHeldSnapshot()
        worker.ping()
        try await settle { model.currentUID(for: .output) == "airpods" }

        XCTAssertEqual(model.pinnedUID(for: .output), "airpods")
        XCTAssertEqual(model.currentUID(for: .output), "airpods")
        XCTAssertFalse(
            worker.setDefaultCalls.contains { $0.uid == "speakers" },
            "stale snapshot must never restore the previous pin"
        )
    }

    /// Manual rescan re-reads hardware (e.g. after moving between docks)
    /// and restores a pin that has reappeared.
    func testRescanPicksUpReappearedPinnedDevice() async throws {
        let speakers = worker.devices.first { $0.uid == "speakers" }!
        // Dock unplugged: pinned speakers vanish, system falls back.
        worker.devices = worker.devices.filter { $0.uid != "speakers" }
        worker.setSystemDefault("airpods", for: .output)
        model.rescanDevices()
        try await settle { model.status(for: .output) == .waitingForPinnedDevice }

        // Dock replugged at the other desk: device is back, rescan restores.
        worker.devices += [speakers]
        model.rescanDevices()
        try await settle { model.currentUID(for: .output) == "speakers" }
        XCTAssertEqual(model.currentUID(for: .output), "speakers")
    }

    func testSettingsRoundTrip() {
        settings.setPin(uid: "abc", name: "Some Device", for: .input)
        XCTAssertEqual(settings.pinnedUID(for: .input), "abc")
        XCTAssertEqual(settings.pinnedName(for: .input), "Some Device")

        settings.setPin(uid: nil, name: nil, for: .input)
        XCTAssertNil(settings.pinnedUID(for: .input))
        XCTAssertNil(settings.pinnedName(for: .input))

        XCTAssertTrue(settings.keepingEnabled(for: .input), "keeping defaults to on")
        settings.setKeepingEnabled(false, for: .input)
        XCTAssertFalse(settings.keepingEnabled(for: .input))
    }
}
