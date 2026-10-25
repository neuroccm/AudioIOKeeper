import XCTest
@testable import AudioIOKeeper

private func pinTestDevice(uid: String, name: String, input: Bool, output: Bool) -> AudioDevice {
    AudioDevice(objectID: UInt32(abs(uid.hashValue % 10_000)), uid: uid, name: name,
                transport: .builtIn, hasInput: input, hasOutput: output, isAlive: true)
}

/// The clickable per-device pin is the lock: pinning a device uses it now
/// and locks it in, clicking the blue pin again unlocks without changing
/// the device in use, and an unlocked direction stays unlocked on relaunch.
@MainActor
final class AppModelPinTests: XCTestCase {
    private var worker: FakeAudioHardwareWorker!
    private var settings: SettingsStore!
    private var clock: FakeClock!
    private var model: AppModel!
    private var suiteName: String!

    override func setUp() async throws {
        worker = FakeAudioHardwareWorker()
        clock = FakeClock()
        suiteName = "AudioIOKeeperPinTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)

        let speakers = pinTestDevice(uid: "speakers", name: "Studio Speakers", input: false, output: true)
        let airPods = pinTestDevice(uid: "airpods", name: "AirPods", input: true, output: true)
        let mic = pinTestDevice(uid: "usb-mic", name: "USB Mic", input: true, output: false)
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

    private func settle(timeout: TimeInterval = 3, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Pinning a different device must lock it in even when keeping was off:
    /// a blue pin that does not actually enforce is the reported bug.
    func testPinningDeviceUsesItAndLocksItEvenWhenKeepingWasOff() async throws {
        model.setKeepingEnabled(false, for: .output)
        let airPods = worker.devices.first { $0.uid == "airpods" }!

        model.togglePin(airPods, for: .output)

        XCTAssertEqual(model.pinnedUID(for: .output), "airpods")
        XCTAssertTrue(model.keepingEnabled(for: .output), "pinning turns locking back on")
        try await settle { model.currentUID(for: .output) == "airpods" }
        XCTAssertEqual(model.currentUID(for: .output), "airpods", "pinning uses the device right away")

        // Wait for the restore *write*, not the cached current: the cache
        // already reads "airpods" before the switch is even processed, so
        // waiting on it would pass even if reconciliation never ran.
        worker.resetRecordedCalls()
        worker.simulateSystemSwitch(to: "speakers", for: .output)
        try await settle {
            worker!.setDefaultCalls.contains { $0.uid == "airpods" && $0.direction == .output }
        }
        XCTAssertEqual(
            worker.setDefaultCalls.filter { $0.direction == .output }.map(\.uid),
            ["airpods"], "a system switch is restored to the pin exactly once"
        )
        XCTAssertEqual(worker.systemDefault(for: .output), "airpods")
        XCTAssertEqual(model.currentUID(for: .output), "airpods")
    }

    /// Clicking the pin of the pinned device unlocks it: the device stays
    /// in use, but macOS may switch away freely afterwards.
    func testTogglingPinnedDeviceUnpinsAndUnlocksIt() async throws {
        let speakers = worker.devices.first { $0.uid == "speakers" }!
        worker.resetRecordedCalls()

        model.togglePin(speakers, for: .output)

        XCTAssertNil(model.pinnedUID(for: .output))
        XCTAssertFalse(model.keepingEnabled(for: .output))
        XCTAssertEqual(model.currentUID(for: .output), "speakers", "unpinning must not switch the device in use")

        worker.simulateSystemSwitch(to: "airpods", for: .output)
        try await settle { model.currentUID(for: .output) == "airpods" }
        XCTAssertTrue(worker.setDefaultCalls.isEmpty, "no restores once unpinned")
    }

    /// An unpin is a deliberate choice: relaunching must not silently
    /// re-pin whatever happens to be current (first-launch adoption is
    /// only for a truly fresh install).
    func testUnpinSurvivesRelaunchWithoutRepinningCurrentDefault() async throws {
        let speakers = worker.devices.first { $0.uid == "speakers" }!
        model.togglePin(speakers, for: .output)
        XCTAssertNil(model.pinnedUID(for: .output))

        let clock = self.clock!
        let relaunched = AppModel(worker: worker, settings: settings, now: { clock.now() })
        relaunched.start()
        try await settle { relaunched.currentUID(for: .output) == "speakers" }

        XCTAssertNil(relaunched.pinnedUID(for: .output), "relaunch must not undo the user's unpin")
        XCTAssertFalse(relaunched.keepingEnabled(for: .output))
    }

    /// First-launch adoption is per direction: a direction whose default
    /// could not be read on the first snapshot stays pending and is adopted
    /// once its default appears, while a direction the user already
    /// unpinned is never re-adopted.
    func testFirstLaunchAdoptionRetriesDirectionWhoseDefaultWasMissing() async throws {
        let localSuite = "AudioIOKeeperPinTests-Adopt-\(UUID().uuidString)"
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer { localDefaults.removePersistentDomain(forName: localSuite) }
        let localSettings = SettingsStore(defaults: localDefaults)

        let localWorker = FakeAudioHardwareWorker()
        let speakers = pinTestDevice(uid: "speakers", name: "Studio Speakers", input: false, output: true)
        let mic = pinTestDevice(uid: "usb-mic", name: "USB Mic", input: true, output: false)
        localWorker.devices = [speakers, mic]
        localWorker.setSystemDefault("speakers", for: .output)
        // No input default on the first snapshot (unreadable/unknown default).

        let clock = self.clock!
        let fresh = AppModel(worker: localWorker, settings: localSettings, now: { clock.now() })
        fresh.start()
        try await settle { fresh.pinnedUID(for: .output) == "speakers" }
        XCTAssertNil(fresh.pinnedUID(for: .input), "no default yet, nothing to adopt")

        // The user unpins output while input adoption is still pending.
        fresh.togglePin(speakers, for: .output)
        XCTAssertNil(fresh.pinnedUID(for: .output))

        // The input default appears; only the pending direction is adopted.
        localWorker.simulateSystemSwitch(to: "usb-mic", for: .input)
        try await settle { fresh.pinnedUID(for: .input) == "usb-mic" }
        XCTAssertEqual(fresh.pinnedUID(for: .input), "usb-mic", "pending direction is adopted once readable")
        XCTAssertNil(fresh.pinnedUID(for: .output), "the user's unpin must not be undone by adoption")
    }

    func testDisabledDirectionCompletesAdoptionWithoutPinningEvenAfterRelaunch() async throws {
        let localSuite = "Adoption-\(UUID().uuidString)"
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer { localDefaults.removePersistentDomain(forName: localSuite) }
        let localSettings = SettingsStore(defaults: localDefaults)
        localSettings.setKeepingEnabled(false, for: .input)
        let localWorker = FakeAudioHardwareWorker()
        localWorker.devices = worker.devices
        localWorker.setSystemDefault("speakers", for: .output)
        // Disabled input must complete adoption even without a readable default.
        let fresh = AppModel(worker: localWorker, settings: localSettings)
        fresh.start()
        try await settle { fresh.pinnedUID(for: .output) == "speakers" }

        XCTAssertTrue(localSettings.didAdoptInitialPin(for: .input))
        XCTAssertNil(fresh.pinnedUID(for: .input))
        XCTAssertFalse(fresh.keepingEnabled(for: .input))

        localWorker.setSystemDefault("usb-mic", for: .input)
        let relaunched = AppModel(worker: localWorker, settings: localSettings)
        relaunched.start()
        try await settle { relaunched.currentUID(for: .input) == "usb-mic" }
        XCTAssertNil(relaunched.pinnedUID(for: .input))
        XCTAssertFalse(relaunched.keepingEnabled(for: .input))
        XCTAssertTrue(localWorker.setDefaultCalls.isEmpty)

        relaunched.setKeepingEnabled(true, for: .input)
        try await settle { relaunched.keepingEnabled(for: .input) }
        XCTAssertNil(relaunched.pinnedUID(for: .input), "completed adoption must not run when keeping is enabled later")
    }

    func testUnpinAfterSelectionReachesWorkerSkipsWriteAndPreservesOtherDirection() async throws {
        try await checkUnpinDuringSelection(at: .read)
    }

    func testUnpinDuringHALWriteRestoresDeviceThatWasInUse() async throws {
        try await checkUnpinDuringSelection(at: .write)
    }

    private func checkUnpinDuringSelection(at point: GatedDeviceClient.GatePoint) async throws {
        let client = GatedDeviceClient()
        let serialWorker = AudioHardwareWorker(client: client)
        let localModel = AppModel(worker: serialWorker, settings: settings)
        localModel.start()
        try await settle { localModel.currentUID(for: .output) == "speakers" }

        client.holdNextOutputOperation(at: point)
        defer { client.release() }
        let airPods = client.devices.first { $0.uid == "airpods" }!
        localModel.selectDevice(airPods, for: .output)
        try await settle { client.isHeld }
        XCTAssertTrue(client.isHeld, "selection must have reached the worker before unpinning")

        localModel.selectDevice(airPods, for: .input)
        localModel.unpinDevice(for: .output)
        client.release()

        let snapshot = await serialWorker.snapshot()
        try await settle { localModel.currentUID(for: .input) == "airpods" }
        XCTAssertEqual(snapshot.defaultUID(for: .output), "speakers")
        XCTAssertEqual(localModel.currentUID(for: .output), "speakers")
        XCTAssertNil(localModel.pinnedUID(for: .output))
        XCTAssertFalse(localModel.keepingEnabled(for: .output))
        XCTAssertEqual(localModel.pinnedUID(for: .input), "airpods")
        XCTAssertEqual(localModel.currentUID(for: .input), "airpods")
        XCTAssertTrue(localModel.keepingEnabled(for: .input))
        XCTAssertEqual(client.setDefaultCalls.filter { $0.direction == .output }.map(\.uid),
                       point == .read ? [] : ["airpods", "speakers"])
    }

    func testUnpinAfterCompletedSelectionKeepsSelectedDeviceInUse() async throws {
        let airPods = worker.devices.first { $0.uid == "airpods" }!
        model.selectDevice(airPods, for: .output)
        try await settle { model.currentUID(for: .output) == "airpods" }
        worker.resetRecordedCalls()

        model.unpinDevice(for: .output)
        try await settle { model.pinnedUID(for: .output) == nil }

        XCTAssertEqual(worker.systemDefault(for: .output), "airpods")
        XCTAssertEqual(model.currentUID(for: .output), "airpods")
        XCTAssertTrue(worker.setDefaultCalls.isEmpty)
    }

    /// Pin then immediately unpin (before the selection switch has run):
    /// the pending switch is cancelled, so unpinning keeps the device
    /// that was in use.
    func testRapidUnpinCancelsPendingSelectionSwitch() async throws {
        let airPods = worker.devices.first { $0.uid == "airpods" }!
        worker.resetRecordedCalls()

        model.togglePin(airPods, for: .output)
        model.togglePin(airPods, for: .output)

        try await settle { model.pinnedUID(for: .output) == nil }
        XCTAssertNil(model.pinnedUID(for: .output))
        XCTAssertTrue(
            worker.setDefaultCalls.filter { $0.direction == .output }.isEmpty,
            "a selection cancelled by unpin must not switch the device"
        )
        XCTAssertEqual(worker.systemDefault(for: .output), "speakers")
        XCTAssertEqual(model.currentUID(for: .output), "speakers")
    }
}
