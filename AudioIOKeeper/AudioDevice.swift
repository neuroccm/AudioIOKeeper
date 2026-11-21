import Foundation

/// Direction of an audio data flow.
enum AudioDirection: String, Sendable, CaseIterable {
    case input
    case output

    var displayName: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        }
    }

    var systemImage: String {
        switch self {
        case .input: "mic"
        case .output: "speaker.wave.2"
        }
    }
}

/// How a device is connected, used to pick an icon and disambiguate identical names.
enum TransportType: Sendable, Equatable, CaseIterable {
    case builtIn
    case bluetooth
    case usb
    case display
    case thunderbolt
    case airPlay
    case continuity
    case virtual
    case aggregate
    case other

    var systemImage: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .display: "display"
        case .thunderbolt: "bolt"
        case .airPlay: "airplayaudio"
        case .continuity: "iphone"
        case .virtual: "waveform.path.ecg"
        case .aggregate: "square.stack.3d.up"
        case .other: "speaker.wave.2"
        }
    }

    var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .display: "Display"
        case .thunderbolt: "Thunderbolt"
        case .airPlay: "AirPlay"
        case .continuity: "Continuity"
        case .virtual: "Virtual"
        case .aggregate: "Aggregate"
        case .other: "Audio"
        }
    }
}

/// A snapshot of one audio device as reported by Core Audio.
///
/// Devices are identified by their persistent `uid` (stable across reboots and
/// reconnects), never by the volatile `AudioDeviceID`, so a pin survives the
/// device being unplugged and plugged back in.
struct AudioDevice: Identifiable, Hashable, Sendable {
    /// Core Audio object id. Valid only for the current session.
    let objectID: UInt32
    /// Persistent device UID (`kAudioDevicePropertyDeviceUID`).
    let uid: String
    let name: String
    let transport: TransportType
    /// Specific port or transport label (e.g. "HDMI" vs "DisplayPort") for disambiguation.
    let portLabel: String?
    let hasInput: Bool
    let hasOutput: Bool
    let isAlive: Bool
    /// Whether macOS allows this device as the system alert/sound-effects output.
    let canBeDefaultSystemOutput: Bool

    init(
        objectID: UInt32,
        uid: String,
        name: String,
        transport: TransportType,
        hasInput: Bool,
        hasOutput: Bool,
        isAlive: Bool,
        canBeDefaultSystemOutput: Bool? = nil,
        portLabel: String? = nil
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.transport = transport
        self.portLabel = portLabel
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.isAlive = isAlive
        self.canBeDefaultSystemOutput = canBeDefaultSystemOutput ?? hasOutput
    }

    var id: String { uid }

    func supports(_ direction: AudioDirection) -> Bool {
        switch direction {
        case .input: hasInput
        case .output: hasOutput
        }
    }

    /// Returns UID-keyed display labels, adding port/UID qualifiers only when
    /// two or more devices in the same list share an identical `name` (such as
    /// dual monitors or HDMI + DisplayPort endpoints on the same display).
    static func disambiguatedNames(for devices: [AudioDevice]) -> [String: String] {
        let byName = Dictionary(grouping: devices) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var result: [String: String] = [:]
        for group in byName.values {
            if group.count == 1, let single = group.first {
                result[single.uid] = single.name
                continue
            }
            let portQualified: [(device: AudioDevice, label: String)] = group.map { device in
                let qualifier = device.portLabel ?? device.transport.displayName
                return (device, "\(device.name) (\(qualifier))")
            }
            let byQualified = Dictionary(grouping: portQualified) { $0.label.lowercased() }
            for items in byQualified.values {
                if items.count == 1, let single = items.first {
                    result[single.device.uid] = single.label
                } else {
                    for (index, item) in items.enumerated() {
                        let suffix = shortUIDToken(item.device.uid) ?? "#\(index + 1)"
                        let qualifier = item.device.portLabel ?? item.device.transport.displayName
                        result[item.device.uid] = "\(item.device.name) (\(qualifier) · \(suffix))"
                    }
                }
            }
        }
        return result
    }

    private static func shortUIDToken(_ uid: String) -> String? {
        let cleaned = uid.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard cleaned.count >= 4 else { return nil }
        return String(String.UnicodeScalarView(cleaned.suffix(4))).uppercased()
    }
}

/// One entry in the visible activity log: the keeper never acts invisibly.
struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let message: String
}

/// Abstraction over the Core Audio HAL so the app model can be tested with a
/// fake and so all unsafe C-API calls live in `AudioHardwareClient.swift`.
protocol AudioHardwareClient: Sendable {
    func allDevices() -> [AudioDevice]
    func defaultDeviceUID(for direction: AudioDirection) -> String?
    @discardableResult
    func setDefaultDevice(uid: String, for direction: AudioDirection) -> Bool
    func defaultSystemOutputUID() -> String?
    @discardableResult
    func setDefaultSystemOutputDevice(uid: String) -> Bool
    func addChangeListener(_ handler: @escaping @Sendable () -> Void)
    func ensureListenersInstalled()
}

extension AudioHardwareClient {
    func defaultSystemOutputUID() -> String? { nil }
    @discardableResult func setDefaultSystemOutputDevice(uid: String) -> Bool { false }
    func ensureListenersInstalled() {}
}
