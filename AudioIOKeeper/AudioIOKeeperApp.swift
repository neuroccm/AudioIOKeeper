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
            Label("Audio IO Keeper", systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    /// The menu bar icon doubles as a status light:
    /// locked waveform = keeping, plain waveform = keeping off,
    /// warning = a pinned device is currently disconnected.
    private var menuBarSymbol: String {
        if model.isAnyDirectionWaiting { return "waveform.badge.exclamationmark" }
        return model.isKeepingAnything ? "waveform.badge.lock" : "waveform"
    }
}
