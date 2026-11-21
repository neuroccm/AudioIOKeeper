import AppKit
import SwiftUI

/// Starts the keeper the moment the app launches and reconciles on wake.
///
/// The keeper must not be tied to the menu bar popover's lifecycle:
/// `MenuBarExtra` content is only created when the user opens it, so
/// starting from the view (e.g. `onAppear`) would leave the app doing
/// nothing until the first click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var wakeObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.handleSystemWake()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        model.stop()
    }
}

/// Audio IO Keeper is a menu-bar-only app (`LSUIElement`): no Dock icon, no
/// main window. All interaction happens in the menu bar popover plus a small
/// Settings window.
@main
struct AudioIOKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// SF Symbol names for the menu bar status icon.
///
/// Every name here must be a real symbol on the oldest supported macOS
/// (14.0): `Image(systemName:)` with a nonexistent name renders as an
/// empty, zero-width image, which in a menu bar item looks exactly like
/// the app has vanished. `MenuBarSymbolTests` asserts each name resolves.
enum MenuBarSymbol {
    /// Keeping is on and every pinned device is present.
    static let keeping = "waveform.circle.fill"
    /// Keeping is off in both directions.
    static let idle = "waveform"
    /// A pinned device is disconnected (or a direction is conflicted).
    static let waiting = "waveform.badge.exclamationmark"

    static let all = [keeping, idle, waiting]

    static func name(isWaiting: Bool, isKeeping: Bool) -> String {
        if isWaiting { return waiting }
        return isKeeping ? keeping : idle
    }
}

/// The menu bar item's label, as its own view so the model's observable
/// state is read (and tracked) here instead of in the app's scene builder.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Label(
            "Audio IO Keeper",
            systemImage: MenuBarSymbol.name(
                isWaiting: model.isAnyDirectionWaiting,
                isKeeping: model.isActivelyKeepingAnything
            )
        )
    }
}

// MARK: - Derived UI state

extension AppModel {

    func devices(for direction: AudioDirection) -> [AudioDevice] {
        devices.filter { $0.supports(direction) }
    }

    func displayName(for device: AudioDevice, direction: AudioDirection) -> String {
        let names = AudioDevice.disambiguatedNames(for: devices(for: direction))
        return names[device.uid] ?? device.name
    }

    func currentUID(for direction: AudioDirection) -> String? {
        currentDefaultUID[direction] ?? nil
    }

    func pinnedUID(for direction: AudioDirection) -> String? {
        pinnedUIDs[direction]
    }

    func pinnedName(for direction: AudioDirection) -> String? {
        guard let uid = pinnedUIDs[direction] else { return nil }
        if let connected = devices(for: direction).first(where: { $0.uid == uid }) {
            return displayName(for: connected, direction: direction)
        }
        return pinnedNames[direction]
    }

    func keepingEnabled(for direction: AudioDirection) -> Bool {
        keepingFlags[direction] ?? true
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > now()
    }

    func isConflicting(for direction: AudioDirection) -> Bool {
        throttles[direction]?.isConflicting(now: now()) ?? false
    }

    func status(for direction: AudioDirection) -> DirectionStatus {
        DirectionStatus.status(
            keepingEnabled: keepingEnabled(for: direction),
            pinnedUID: pinnedUID(for: direction),
            currentUID: currentUID(for: direction),
            availableUIDs: Set(devices(for: direction).map(\.uid)),
            inConflict: isConflicting(for: direction),
            isPaused: isPaused
        )
    }

    /// Overall health for the menu bar icon.
    var isAnyDirectionWaiting: Bool {
        AudioDirection.allCases.contains {
            let state = status(for: $0)
            return state == .waitingForPinnedDevice || state == .conflicted
        }
    }

    /// True when at least one direction is both enabled and pinned to a device.
    var isKeepingAnything: Bool {
        AudioDirection.allCases.contains { keepingEnabled(for: $0) && pinnedUID(for: $0) != nil }
    }

    /// `isKeepingAnything` minus an active temporary unlock (menu bar icon).
    var isActivelyKeepingAnything: Bool {
        isKeepingAnything && !isPaused
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            let seconds = max(1, Int(duration.rounded()))
            return seconds == 1 ? "1 second" : "\(seconds) seconds"
        }
        let minutes = Int((duration / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
