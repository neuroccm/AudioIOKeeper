import XCTest
@testable import AudioIOKeeper

/// In-memory fake of the Core Audio HAL used to drive the app model.
final class FakeAudioHardwareClient: AudioHardwareClient, @unchecked Sendable {
    var devices: [AudioDevice] = []
    var defaults: [AudioDirection: String?] = [:]
    private(set) var setDefaultCalls: [(uid: String, direction: AudioDirection)] = []
    private var listener: (@Sendable () -> Void)?

    func allDevices() -> [AudioDevice] { devices }

    func defaultDeviceUID(for direction: AudioDirection) -> String? {
        defaults[direction] ?? nil
    }

    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool {
        setDefaultCalls.append((uid, direction))
        defaults[direction] = uid
        return true
    }

    func addChangeListener(_ handler: @escaping @Sendable () -> Void) {
        listener = handler
    }

    func resetRecordedCalls() { setDefaultCalls.removeAll() }

    /// Simulates macOS switching a default behind the app's back.
    func simulateSystemSwitch(to uid: String, for direction: AudioDirection) {
        defaults[direction] = uid
        listener?()
    }
}

private func makeDevice(uid: String, name: String, input: Bool, output: Bool) -> AudioDevice {
    AudioDevice(objectID: UInt32(abs(uid.hashValue % 10_000)), uid: uid, name: name,
                transport: .builtIn, hasInput: input, hasOutput: output, isAlive: true)
}

@MainActor
final class AppModelTests: XCTestCase {
    private var client: FakeAudioHardwareClient!
    private var settings: SettingsStore!
    private var model: AppModel!
    private var suiteName: String!

    override func setUp() async throws {
        client = FakeAudioHardwareClient()
        suiteName = "AudioIOKeeperTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)

        let speakers = makeDevice(uid: "speakers", name: "Studio Speakers", input: false, output: true)
        let airPods = makeDevice(uid: "airpods", name: "AirPods", input: true, output: true)
        let mic = makeDevice(uid: "usb-mic", name: "USB Mic", input: true, output: false)
        client.devices = [speakers, airPods, mic]
        client.defaults = [.output: "speakers", .input: "usb-mic"]

        model = AppModel(client: client, settings: settings)
        model.start()
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func testFirstLaunchAdoptsCurrentDefaultsAsPins() {
        XCTAssertEqual(model.pinnedUID(for: .output), "speakers")
        XCTAssertEqual(model.pinnedUID(for: .input), "usb-mic")
        XCTAssertTrue(client.setDefaultCalls.isEmpty, "adopting pins must not change the system")
    }

    func testSelectingDevicePinsAndAppliesIt() {
        let airPods = client.devices.first { $0.uid == "airpods" }!
        model.selectDevice(airPods, for: .output)
        XCTAssertEqual(model.pinnedUID(for: .output), "airpods")
        XCTAssertEqual(client.setDefaultCalls.last?.uid, "airpods")
        XCTAssertEqual(model.currentUID(for: .output), "airpods")
    }

    /// The core promise: an automatic system switch (AirPods taken out,
    /// Continuity device appearing) is reverted to the pinned device.
    func testAutomaticSwitchIsRevertedToPin() async throws {
        client.simulateSystemSwitch(to: "airpods", for: .output)

        // The change listener coalesces for ~50 ms before enforcing.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(client.setDefaultCalls.last?.uid, "speakers")
        XCTAssertEqual(client.setDefaultCalls.last?.direction, .output)
        XCTAssertEqual(model.currentUID(for: .output), "speakers")
        XCTAssertTrue(
            model.activityLog.contains { $0.message.contains("Restored output") },
            "a restore must be visible in the activity log"
        )
    }

    func testAutomaticSwitchIsLeftAloneWhenKeepingOff() async throws {
        model.setKeepingEnabled(false, for: .output)
        client.resetRecordedCalls()

        client.simulateSystemSwitch(to: "airpods", for: .output)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(client.setDefaultCalls.isEmpty)
        XCTAssertEqual(model.currentUID(for: .output), "airpods")
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
