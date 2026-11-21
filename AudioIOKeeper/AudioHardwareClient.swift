import CoreAudio
import Foundation
import OSLog

/// Live Core Audio implementation using only public HAL properties.
final class CoreAudioHardwareClient: AudioHardwareClient, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.neuroccm.AudioIOKeeper", category: "CoreAudio")
    private let listenerQueue = DispatchQueue(label: "com.neuroccm.AudioIOKeeper.coreaudio-listeners")
    private let lock = NSLock()
    private let listenerLifecycleLock = NSLock()
    private var handlers: [@Sendable () -> Void] = []
    private var installedListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [AudioObjectID: ([AudioObjectPropertySelector], AudioObjectPropertyListenerBlock)] = [:]
    private var listenersInstalled = false

    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioHardwarePropertyServiceRestarted
    ]

    private static let deviceSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyIsHidden,
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyName,
        kAudioDevicePropertyDataSource
    ]

    deinit { removeListeners() }

    // MARK: - Device enumeration

    func allDevices() -> [AudioDevice] {
        let ids = deviceObjectIDs()
        if hasHandlers { syncDeviceListeners(for: ids) }
        return ids.compactMap { makeDevice(objectID: $0) }
            .filter { $0.isAlive && ($0.hasInput || $0.hasOutput) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order != .orderedSame ? order == .orderedAscending : lhs.uid < rhs.uid
            }
    }

    private func deviceObjectIDs() -> [AudioObjectID] {
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return Array(ids.prefix(min(count, Int(dataSize) / MemoryLayout<AudioObjectID>.size)))
    }

    private func makeDevice(objectID: AudioObjectID) -> AudioDevice? {
        guard objectID != AudioObjectID(kAudioObjectUnknown),
              !isHidden(objectID),
              let uid = stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(objectID, selector: kAudioObjectPropertyName) ?? uid
        let hasInput = hasSelectableChannels(objectID, scope: kAudioObjectPropertyScopeInput)
            && canBeDefaultDevice(objectID, scope: kAudioObjectPropertyScopeInput)
        let hasOutput = hasSelectableChannels(objectID, scope: kAudioObjectPropertyScopeOutput)
            && canBeDefaultDevice(objectID, scope: kAudioObjectPropertyScopeOutput)
        let (transport, portLabel) = transportInfo(
            from: uint32Property(objectID, selector: kAudioDevicePropertyTransportType)
        )
        return AudioDevice(
            objectID: objectID, uid: uid, name: name, transport: transport,
            hasInput: hasInput, hasOutput: hasOutput,
            isAlive: isDeviceAlive(objectID),
            canBeDefaultSystemOutput: hasOutput && canBeDefaultSystemDevice(objectID),
            portLabel: portLabel
        )
    }

    // MARK: - Defaults

    private func defaultUID(selector: AudioObjectPropertySelector) -> String? {
        var addr = propertyAddress(selector)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func defaultDeviceUID(for direction: AudioDirection) -> String? { defaultUID(selector: selector(for: direction)) }
    func defaultSystemOutputUID() -> String? { defaultUID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice) }

    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool {
        guard let resolvedID = resolveEligibleDevice(uid: uid, scope: scope(for: direction), systemOutput: false) else {
            let dir = direction.rawValue
            logger.error("Cannot set default \(dir, privacy: .public): device \(uid, privacy: .public) unavailable")
            return false
        }
        return writeSystemDefault(deviceID: resolvedID, selector: selector(for: direction), label: direction.rawValue)
    }

    @discardableResult
    func setDefaultSystemOutputDevice(uid: String) -> Bool {
        guard let resolvedID = resolveEligibleDevice(
            uid: uid, scope: kAudioObjectPropertyScopeOutput, systemOutput: true
        ) else {
            logger.error("Cannot set system output: device \(uid, privacy: .public) unavailable")
            return false
        }
        return writeSystemDefault(
            deviceID: resolvedID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, label: "system output"
        )
    }

    private func resolveEligibleDevice(
        uid: String, scope: AudioObjectPropertyScope, systemOutput: Bool
    ) -> AudioObjectID? {
        guard let resolvedID = deviceID(forUID: uid),
              !isHidden(resolvedID),
              isDeviceAlive(resolvedID),
              hasSelectableChannels(resolvedID, scope: scope) else { return nil }
        return (systemOutput ? canBeDefaultSystemDevice(resolvedID) : canBeDefaultDevice(resolvedID, scope: scope))
            ? resolvedID : nil
    }

    private func writeSystemDefault(
        deviceID resolvedID: AudioObjectID, selector: AudioObjectPropertySelector, label: String
    ) -> Bool {
        var addr = propertyAddress(selector)
        var deviceID = resolvedID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &deviceID
        )
        if status != noErr { logger.error("Setting default \(label, privacy: .public) failed with OSStatus \(status)") }
        return status == noErr
    }

    func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        let cfUID = uid as CFString
        var unmanagedUID = Unmanaged.passUnretained(cfUID)
        var resolvedID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status: OSStatus = withExtendedLifetime(cfUID) {
            withUnsafeMutablePointer(to: &unmanagedUID) { qualifier in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &addr,
                    UInt32(MemoryLayout<Unmanaged<CFString>>.size), qualifier, &dataSize, &resolvedID
                )
            }
        }
        if status == noErr, resolvedID != AudioObjectID(kAudioObjectUnknown) { return resolvedID }
        return deviceObjectIDs().first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: - Change listeners

    private var hasHandlers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !handlers.isEmpty
    }

    func addChangeListener(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        handlers.append(handler)
        let shouldInstall = !listenersInstalled
        lock.unlock()
        if shouldInstall { installListeners() }
    }

    func ensureListenersInstalled() {
        lock.lock()
        let shouldInstall = !handlers.isEmpty && !listenersInstalled
        lock.unlock()
        if shouldInstall { installListeners() }
    }

    private func installListeners() {
        listenerLifecycleLock.lock()
        defer { listenerLifecycleLock.unlock() }
        removeListenersLocked()
        var registered: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
        var allSucceeded = true
        for selector in Self.watchedSelectors {
            var addr = propertyAddress(selector)
            let isServiceRestart = selector == kAudioHardwarePropertyServiceRestarted
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                if isServiceRestart { self?.handleServiceRestart() } else { self?.notifyHandlers() }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block
            )
            if status == noErr {
                registered.append((selector, block))
            } else {
                allSucceeded = false
                logger.error("Failed to install listener for selector \(selector) (OSStatus \(status))")
            }
        }
        lock.lock()
        installedListeners = registered
        listenersInstalled = allSucceeded
        lock.unlock()
    }

    private func syncDeviceListeners(for currentIDs: [AudioObjectID]) {
        listenerLifecycleLock.lock()
        defer { listenerLifecycleLock.unlock() }
        let wanted = Set(currentIDs).subtracting([AudioObjectID(kAudioObjectUnknown)])
        for obsoleteID in Set(deviceListeners.keys).subtracting(wanted) { removeDeviceListenerLocked(for: obsoleteID) }
        for objectID in wanted where deviceListeners[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notifyHandlers() }
            let active = Self.deviceSelectors.filter { selector in
                var addr = propertyAddress(selector, scope: kAudioObjectPropertyScopeWildcard)
                return AudioObjectAddPropertyListenerBlock(objectID, &addr, listenerQueue, block) == noErr
            }
            if !active.isEmpty { deviceListeners[objectID] = (active, block) }
        }
    }

    private func removeDeviceListenerLocked(for objectID: AudioObjectID) {
        guard let (selectors, block) = deviceListeners.removeValue(forKey: objectID) else { return }
        for selector in selectors {
            var addr = propertyAddress(selector, scope: kAudioObjectPropertyScopeWildcard)
            _ = AudioObjectRemovePropertyListenerBlock(objectID, &addr, listenerQueue, block)
        }
    }

    private func removeListeners() {
        listenerLifecycleLock.lock()
        defer { listenerLifecycleLock.unlock() }
        removeListenersLocked()
    }

    private func removeListenersLocked() {
        for objectID in Array(deviceListeners.keys) { removeDeviceListenerLocked(for: objectID) }
        lock.lock()
        let existing = installedListeners
        installedListeners.removeAll()
        listenersInstalled = false
        lock.unlock()
        for (selector, block) in existing {
            var addr = propertyAddress(selector)
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block
            )
        }
    }

    private func handleServiceRestart() {
        logger.warning("Core Audio service restarted — re-establishing HAL property listeners")
        installListeners()
        notifyHandlers()
    }

    private func notifyHandlers() {
        lock.lock()
        let snapshot = handlers
        lock.unlock()
        snapshot.forEach { $0() }
    }
}

// MARK: - Property helpers

private extension CoreAudioHardwareClient {
    func selector(for direction: AudioDirection) -> AudioObjectPropertySelector {
        direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    func scope(for direction: AudioDirection) -> AudioObjectPropertyScope {
        direction == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    func propertyAddress(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, $0)
        }
        guard status == noErr, dataSize == UInt32(MemoryLayout<Unmanaged<CFString>?>.size), let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    func uint32Property(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32 {
        var addr = propertyAddress(selector, scope: scope)
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, &value) == noErr ? value : 0
    }

    func isHidden(_ objectID: AudioObjectID) -> Bool {
        uint32PropertyIfPresent(objectID, selector: kAudioDevicePropertyIsHidden, defaultValue: 0) != 0
    }

    func isDeviceAlive(_ objectID: AudioObjectID) -> Bool {
        uint32PropertyIfPresent(objectID, selector: kAudioDevicePropertyDeviceIsAlive, defaultValue: 1) != 0
    }

    func canBeDefaultDevice(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        scopedOrGlobalFlag(objectID, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope)
    }

    func canBeDefaultSystemDevice(_ objectID: AudioObjectID) -> Bool {
        scopedOrGlobalFlag(
            objectID, selector: kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: kAudioObjectPropertyScopeOutput
        )
    }

    func scopedOrGlobalFlag(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> Bool {
        var scopedAddr = propertyAddress(selector, scope: scope)
        if AudioObjectHasProperty(objectID, &scopedAddr) {
            return uint32Property(objectID, selector: selector, scope: scope) != 0
        }
        return uint32PropertyIfPresent(objectID, selector: selector, defaultValue: 1) != 0
    }

    func uint32PropertyIfPresent(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, defaultValue: UInt32
    ) -> UInt32 {
        var addr = propertyAddress(selector, scope: scope)
        guard AudioObjectHasProperty(objectID, &addr) else { return defaultValue }
        return uint32Property(objectID, selector: selector, scope: scope)
    }

    func hasSelectableChannels(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var configAddr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        if AudioObjectHasProperty(objectID, &configAddr) { return channelCount(objectID, scope: scope) > 0 }
        var streamsAddr = propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &streamsAddr, 0, nil, &size) == noErr else { return false }
        return Int(size) >= MemoryLayout<AudioObjectID>.size
    }

    func channelCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, rawBuffer) == noErr,
              Int(dataSize) >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let listPointer = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let maxBuffers = 1 + (Int(dataSize) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride
        listPointer.pointee.mNumberBuffers = UInt32(max(0, min(Int(listPointer.pointee.mNumberBuffers), maxBuffers)))
        return UnsafeMutableAudioBufferListPointer(listPointer).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func transportInfo(from raw: UInt32) -> (TransportType, String?) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: (.builtIn, "Built-in")
        case kAudioDeviceTransportTypeBluetooth: (.bluetooth, "Bluetooth")
        case kAudioDeviceTransportTypeBluetoothLE: (.bluetooth, "Bluetooth LE")
        case kAudioDeviceTransportTypeUSB: (.usb, "USB")
        case kAudioDeviceTransportTypeHDMI: (.display, "HDMI")
        case kAudioDeviceTransportTypeDisplayPort: (.display, "DisplayPort")
        case kAudioDeviceTransportTypeThunderbolt: (.thunderbolt, "Thunderbolt")
        case kAudioDeviceTransportTypeAirPlay: (.airPlay, "AirPlay")
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: (.continuity, "Continuity")
        case kAudioDeviceTransportTypeVirtual: (.virtual, "Virtual")
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: (.aggregate, "Aggregate")
        default: (.other, nil)
        }
    }
}
