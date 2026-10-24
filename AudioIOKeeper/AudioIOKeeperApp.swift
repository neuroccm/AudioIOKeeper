import AppKit
import SwiftUI

/// Starts the keeper the moment the app launches.
///
/// The keeper must not be tied to the menu bar popover's lifecycle:
/// `MenuBarExtra` content is only created when the user opens it, so
/// starting from the view (e.g. `onAppear`) would leave the app doing
/// nothing until the first click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
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
/// the app has vanished. That is how the keeping state used to disappear —
/// it named `waveform.badge.lock`, a symbol that does not exist in any
/// release. `MenuBarSymbolTests` asserts each name resolves to an image.
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
/// Reading it in `Scene` body rebuilds the whole scene graph — including
/// the `MenuBarExtra` item itself — on every model change (each reconcile
/// and activity-log entry), which can make the item flicker or drop.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Label(
            "Audio IO Keeper",
            systemImage: MenuBarSymbol.name(
                isWaiting: model.isAnyDirectionWaiting,
                isKeeping: model.isKeepingAnything
            )
        )
    }
}
