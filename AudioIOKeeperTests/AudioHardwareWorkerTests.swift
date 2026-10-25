import XCTest
@testable import AudioIOKeeper

/// Holds a default read or write so cancellation can race a submitted HAL
/// operation deterministically, without blocking the main actor.
final class GatedDeviceClient: AudioHardwareClient, @unchecked Sendable {
    enum GatePoint { case read, write }

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var nextGate: GatePoint?
    private var held = false
    private var defaults: [AudioDirection: String] = [.output: "speakers", .input: "usb-mic"]
    private var writes: [(uid: String, direction: AudioDirection)] = []

    let devices = [
        AudioDevice(objectID: 1, uid: "speakers", name: "Speakers", transport: .builtIn,
                    hasInput: false, hasOutput: true, isAlive: true),
        AudioDevice(objectID: 2, uid: "airpods", name: "AirPods", transport: .bluetooth,
                    hasInput: true, hasOutput: true, isAlive: true),
        AudioDevice(objectID: 3, uid: "usb-mic", name: "USB Mic", transport: .usb,
                    hasInput: true, hasOutput: false, isAlive: true)
    ]

    var isHeld: Bool { locked { held } }
    var setDefaultCalls: [(uid: String, direction: AudioDirection)] { locked { writes } }

    func holdNextOutputOperation(at point: GatePoint) { locked { nextGate = point } }
    func release() { gate.signal() }
    func allDevices() -> [AudioDevice] { devices }
    func addChangeListener(_ handler: @escaping @Sendable () -> Void) {}

    func defaultDeviceUID(for direction: AudioDirection) -> String? {
        let uid = locked { defaults[direction] }
        waitIfNeeded(at: .read, for: direction)
        return uid
    }

    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool {
        waitIfNeeded(at: .write, for: direction)
        locked {
            writes.append((uid, direction))
            defaults[direction] = uid
        }
        return true
    }

    private func waitIfNeeded(at point: GatePoint, for direction: AudioDirection) {
        let shouldHold = locked {
            guard direction == .output, nextGate == point else { return false }
            nextGate = nil
            held = true
            return true
        }
        guard shouldHold else { return }
        gate.wait()
        locked { held = false }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Fake HAL client whose listener registration blocks until released,
/// modeling a HAL stall during `AudioObjectAddPropertyListenerBlock`.
/// Registration must happen on the worker queue: if `start()` ever calls
/// it synchronously again, the gated test below hangs on the caller.
final class GatedListenerClient: AudioHardwareClient, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var enteredInstall = false
    private var installs = 0
    private var handler: (@Sendable () -> Void)?

    var installEntered: Bool { locked { enteredInstall } }
    var installCount: Int { locked { installs } }
    var listenerInstalled: Bool { locked { handler != nil } }

    func allDevices() -> [AudioDevice] { [] }

    func defaultDeviceUID(for direction: AudioDirection) -> String? { nil }

    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool { false }

    func addChangeListener(_ handler: @escaping @Sendable () -> Void) {
        locked {
            enteredInstall = true
            installs += 1
        }
        gate.wait() // stalled HAL registration, released by the test
        locked { self.handler = handler }
    }

    func releaseInstall() { gate.signal() }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class AudioHardwareWorkerTests: XCTestCase {

    /// `start()` must return immediately even while listener registration
    /// is stalled, registration must still complete (once) on the worker
    /// queue, and the first snapshot must be ordered behind it.
    func testStartDoesNotWaitForListenerInstallation() async throws {
        let client = GatedListenerClient()
        let worker = AudioHardwareWorker(client: client)

        worker.start() // would hang here if registration ran on the caller

        // Registration is entered asynchronously and remains gated.
        let entered = await poll(timeout: 2) { client.installEntered }
        XCTAssertTrue(entered, "registration should be attempted on the worker queue")
        XCTAssertFalse(client.listenerInstalled)

        // A snapshot submitted now is queued behind the stalled install.
        let snapshotTask = Task { await worker.snapshot() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(client.listenerInstalled, "snapshot must not overtake registration")

        client.releaseInstall()
        _ = await snapshotTask.value
        XCTAssertTrue(client.listenerInstalled)
        XCTAssertEqual(client.installCount, 1)

        // Install-once: a second start() must not register again.
        worker.start()
        _ = await worker.snapshot()
        XCTAssertEqual(client.installCount, 1)
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
