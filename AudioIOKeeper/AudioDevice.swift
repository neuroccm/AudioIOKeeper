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

/// How a device is connected, used only to pick a helpful icon.
enum TransportType: Sendable, Equatable, CaseIterable {
    case builtIn
    case bluetooth
    case usb
    case virtual
    case aggregate
    case other

    var systemImage: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .virtual: "waveform.path.ecg"
        case .aggregate: "square.stack.3d.up"
        case .other: "speaker.wave.2"
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
    let hasInput: Bool
    let hasOutput: Bool
    let isAlive: Bool

    var id: String { uid }

    func supports(_ direction: AudioDirection) -> Bool {
        switch direction {
        case .input: hasInput
        case .output: hasOutput
        }
    }
}
