import Foundation

/// An immutable view of the audio hardware captured in one serialized pass.
struct HardwareSnapshot: Sendable {
    /// Monotonically increasing operation number from the worker. The app
    /// model rejects any snapshot older than the newest state it has
    /// already applied, so a slow read can never overwrite a newer write.
    let sequence: UInt64
    let devices: [AudioDevice]
    /// Current default device UID per direction (value may be nil).
    let defaults: [AudioDirection: String?]

    func defaultUID(for direction: AudioDirection) -> String? {
        defaults[direction] ?? nil
    }
}

/// Result of a default-device write, sequenced like snapshots.
struct HardwareWriteResult: Sendable {
    let sequence: UInt64
    let succeeded: Bool
}

/// Async façade over the synchronous Core Audio client.
///
/// All HAL reads, writes, and listener registration are serialized on one
/// dedicated queue, never on the main thread: a slow or stalled driver
/// call can delay this queue but cannot freeze launch, the menu UI, or
/// the Quit button. Change notifications are coalesced (and briefly
/// debounced) here, before they can spawn any work on the main actor — a
/// burst of HAL notifications becomes a single ping.
protocol AudioHardwareWorking: Sendable {
    /// Begins listening for hardware changes. Registration itself runs on
    /// the worker queue and must not block the caller.
    func start()
    /// Current hardware state, read on the worker queue.
    func snapshot() async -> HardwareSnapshot
    /// Sets the system default device, executed on the worker queue in
    /// submission order relative to all other operations. Cancellation skips
    /// queued writes; a write already in HAL is rolled back to its previous
    /// default if it succeeds after cancellation and is still current.
    func setDefaultDevice(uid: String, for direction: AudioDirection) async -> HardwareWriteResult
    /// Coalesced "something changed" pings.
    var changePings: AsyncStream<Void> { get }
}

final class AudioHardwareWorker: AudioHardwareWorking, @unchecked Sendable {
    private let client: any AudioHardwareClient
    private let queue = DispatchQueue(label: "com.neuroccm.AudioIOKeeper.hardware-worker", qos: .userInitiated)

    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var started = false
    private var pingScheduled = false

    let changePings: AsyncStream<Void>
    private let pingContinuation: AsyncStream<Void>.Continuation

    /// How long a burst of notifications is allowed to settle before one
    /// ping is emitted. A trailing read always sees the final state, so
    /// dropping intermediate notifications loses nothing.
    static let pingDebounce: TimeInterval = 0.05

    init(client: any AudioHardwareClient = CoreAudioHardwareClient()) {
        self.client = client
        var continuation: AsyncStream<Void>.Continuation!
        self.changePings = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.pingContinuation = continuation
    }

    func start() {
        lock.lock()
        let shouldInstall = !started
        started = true
        lock.unlock()
        guard shouldInstall else { return }
        // Listener registration is itself a synchronous HAL call
        // (AudioObjectAddPropertyListenerBlock x3): it runs on the worker
        // queue, ahead of the first snapshot enqueued after start(), so a
        // HAL stall during registration delays hardware work only — never
        // launch or the main event loop. The install-once guard above and
        // the client's own guard both still apply.
        queue.async { [weak self] in
            guard let self else { return }
            client.addChangeListener { [weak self] in
                self?.noteHardwareChange()
            }
        }
    }

    func snapshot() async -> HardwareSnapshot {
        await withCheckedContinuation { (continuation: CheckedContinuation<HardwareSnapshot, Never>) in
            queue.async { [self] in
                let devices = client.allDevices()
                var defaults: [AudioDirection: String?] = [:]
                for direction in AudioDirection.allCases {
                    defaults[direction] = client.defaultDeviceUID(for: direction)
                }
                continuation.resume(returning: HardwareSnapshot(
                    sequence: nextSequence(), devices: devices, defaults: defaults
                ))
            }
        }
    }

    func setDefaultDevice(uid: String, for direction: AudioDirection) async -> HardwareWriteResult {
        let cancellation = WriteCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HardwareWriteResult, Never>) in
                queue.async { [self] in
                    let succeeded = writeDefaultDevice(uid: uid, for: direction, cancellation: cancellation)
                    continuation.resume(returning: HardwareWriteResult(
                        sequence: nextSequence(), succeeded: succeeded
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func writeDefaultDevice(
        uid: String, for direction: AudioDirection, cancellation: WriteCancellation
    ) -> Bool {
        guard !cancellation.isCancelled else { return false }
        let previousUID = client.defaultDeviceUID(for: direction)
        guard !cancellation.isCancelled else { return false }
        let succeeded = client.setDefaultDevice(uid: uid, for: direction)
        guard cancellation.isCancelled else { return succeeded }
        // A synchronous HAL call cannot be interrupted. Undo its late effect
        // on this same queue before allowing another selection or snapshot.
        if succeeded, let previousUID, client.defaultDeviceUID(for: direction) == uid {
            client.setDefaultDevice(uid: previousUID, for: direction)
        }
        return false
    }

    /// Task cancellation must reach work already submitted to DispatchQueue.
    private final class WriteCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    // MARK: - Change coalescing

    private func noteHardwareChange() {
        lock.lock()
        if pingScheduled {
            lock.unlock()
            return
        }
        pingScheduled = true
        lock.unlock()

        queue.asyncAfter(deadline: .now() + Self.pingDebounce) { [weak self] in
            guard let self else { return }
            lock.lock()
            pingScheduled = false
            lock.unlock()
            pingContinuation.yield()
        }
    }

    private func nextSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }
}
