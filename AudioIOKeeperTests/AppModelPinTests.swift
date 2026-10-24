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

        worker.simulateSystemSwitch(to: "speakers", for: .output)
        try await settle { model.currentUID(for: .output) == "airpods" }
        XCTAssertEqual(model.currentUID(for: .output), "airpods", "a system switch is restored to the pin")
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
}
