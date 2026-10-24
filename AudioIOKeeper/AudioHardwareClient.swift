import CoreAudio
import Foundation
import OSLog

/// Abstraction over the Core Audio HAL so the app model can be tested with a
/// fake and so all unsafe C-API calls live in one audited place.
protocol AudioHardwareClient: Sendable {
    /// All currently present, alive devices.
    func allDevices() -> [AudioDevice]
    /// The device UID currently set as the system default for a direction.
    func defaultDeviceUID(for direction: AudioDirection) -> String?
    /// Sets the system default device for a direction. Returns success.
    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool
    /// Registers a handler invoked whenever the device list or either default
    /// changes. The handler may be called on an arbitrary queue.
    func addChangeListener(_ handler: @escaping @Sendable () -> Void)
}

/// Live Core Audio implementation.
///
/// Uses only public HAL properties: reading/writing
/// `kAudioHardwarePropertyDefaultInputDevice` /
/// `kAudioHardwarePropertyDefaultOutputDevice` is the documented way to move
/// the system defaults — the same mechanism System Settings uses — so no
/// private API and no system modification is involved.
final class CoreAudioHardwareClient: AudioHardwareClient, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "CoreAudio")
    private let listenerQueue = DispatchQueue(label: "com.neuroccm.AudioIOKeeper.coreaudio-listeners")
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []
    private var listenersInstalled = false

    // MARK: - Device enumeration

    func allDevices() -> [AudioDevice] {
        deviceObjectIDs().compactMap { makeDevice(objectID: $0) }
            .filter { $0.isAlive && ($0.hasInput || $0.hasOutput) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func deviceObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private func makeDevice(objectID: AudioObjectID) -> AudioDevice? {
        guard let uid = stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        let name = stringProperty(objectID, selector: kAudioObjectPropertyName) ?? uid
        return AudioDevice(
            objectID: objectID,
            uid: uid,
            name: name,
            transport: transportType(objectID),
            hasInput: streamCount(objectID, scope: kAudioObjectPropertyScopeInput) > 0,
            hasOutput: streamCount(objectID, scope: kAudioObjectPropertyScopeOutput) > 0,
            isAlive: uint32Property(objectID, selector: kAudioDevicePropertyDeviceIsAlive) != 0
        )
    }

    // MARK: - Defaults

    func defaultDeviceUID(for direction: AudioDirection) -> String? {
        var address = address(for: direction)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool {
        guard let device = allDevices().first(where: { $0.uid == uid && $0.supports(direction) }) else {
            let dir = direction.rawValue
            logger.error("Cannot set default \(dir, privacy: .public): device \(uid, privacy: .public) not present")
            return false
        }
        var address = address(for: direction)
        var deviceID = AudioObjectID(device.objectID)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        if status != noErr {
            logger.error("Setting default \(direction.rawValue, privacy: .public) failed with OSStatus \(status)")
        }
        return status == noErr
    }

    private func address(for direction: AudioDirection) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: direction == .input
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Change listeners

    func addChangeListener(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        handlers.append(handler)
        let shouldInstall = !listenersInstalled
        listenersInstalled = true
        lock.unlock()
        if shouldInstall { installListeners() }
    }

    private func installListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // The block intentionally captures self weakly; the client is a
            // process-lifetime singleton owned by the app model.
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue
            ) { [weak self] _, _ in
                self?.notifyHandlers()
            }
            if status != noErr {
                logger.error("Failed to install listener for selector \(selector) (OSStatus \(status))")
            }
        }
    }

    private func notifyHandlers() {
        lock.lock()
        let snapshot = handlers
        lock.unlock()
        snapshot.forEach { $0() }
    }

    // MARK: - Property helpers

    private func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func uint32Property(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr else {
            return 0
        }
        return value
    }

    private func streamCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr else {
            return 0
        }
        return Int(dataSize) / MemoryLayout<AudioObjectID>.size
    }

    private func transportType(_ objectID: AudioObjectID) -> TransportType {
        switch uint32Property(objectID, selector: kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate: .aggregate
        default: .other
        }
    }
}
