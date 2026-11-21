import AppKit
import SwiftUI
import XCTest
@testable import AudioIOKeeper

/// In-memory login item manager so unit tests never touch host Login Items.
@MainActor
final class FakeLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var errorToThrow: Error?
    var setCalls: [Bool] = []
    var openedSettingsCount = 0

    func setEnabled(_ enabled: Bool) -> Result<LoginItemStatus, Error> {
        setCalls.append(enabled)
        if let errorToThrow { return .failure(errorToThrow) }
        status = enabled ? .enabled : .disabled
        return .success(status)
    }

    func openSystemSettings() { openedSettingsCount += 1 }
}

/// Guards against invented SF Symbol names and verifies menu bar & login-item state.
final class MenuBarSymbolTests: XCTestCase {

    func testMenuBarSymbolsExist() {
        for name in MenuBarSymbol.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "menu bar symbol '\(name)' does not exist; the menu bar item would render empty"
            )
        }
        XCTAssertEqual(Set(MenuBarSymbol.all).count, MenuBarSymbol.all.count, "states must be visually distinct")
    }

    func testMenuBarSymbolSelection() {
        XCTAssertEqual(MenuBarSymbol.name(isWaiting: true, isKeeping: true), MenuBarSymbol.waiting)
        XCTAssertEqual(MenuBarSymbol.name(isWaiting: true, isKeeping: false), MenuBarSymbol.waiting)
        XCTAssertEqual(MenuBarSymbol.name(isWaiting: false, isKeeping: true), MenuBarSymbol.keeping)
        XCTAssertEqual(MenuBarSymbol.name(isWaiting: false, isKeeping: false), MenuBarSymbol.idle)
    }

    func testDirectionAndTransportSymbolsExist() {
        for direction in AudioDirection.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: direction.systemImage, accessibilityDescription: nil),
                "direction symbol '\(direction.systemImage)' does not exist"
            )
        }
        for transport in TransportType.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: transport.systemImage, accessibilityDescription: nil),
                "transport symbol '\(transport.systemImage)' does not exist"
            )
        }
    }

    @MainActor
    func testIsKeepingAnythingRequiresActivePin() {
        let suite = "AudioIOKeeperTests-MenuBar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        // Keeping defaults to enabled, but no pins are selected yet.
        let model = AppModel(
            worker: FakeAudioHardwareWorker(),
            settings: settings,
            loginItem: FakeLoginItemManager()
        )
        XCTAssertFalse(model.isKeepingAnything, "enabled keeping with no pin must not claim active locking")
        XCTAssertFalse(model.isActivelyKeepingAnything)
    }

    @MainActor
    func testLoginItemFailureRevertsToggleAndSurfacesApproval() {
        let suite = "AudioIOKeeperTests-LoginItem-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = FakeLoginItemManager()
        let model = AppModel(
            worker: FakeAudioHardwareWorker(),
            settings: SettingsStore(defaults: defaults),
            loginItem: login
        )

        login.errorToThrow = NSError(domain: "LoginTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Registration blocked"
        ])
        model.setLaunchAtLogin(true)
        XCTAssertFalse(model.launchAtLogin, "failed registration must not leave the toggle enabled")
        XCTAssertEqual(model.loginItemError, "Registration blocked")

        login.errorToThrow = nil
        login.status = .requiresApproval
        model.refreshLoginItemStatus()
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertTrue(model.loginItemNeedsApproval)

        model.openLoginItemsSettings()
        XCTAssertEqual(login.openedSettingsCount, 1)

        login.status = .enabled
        model.refreshLoginItemStatus()
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertFalse(model.loginItemNeedsApproval)
    }

    func testDisambiguatedNamesDistinguishesDuplicateDisplaysByPortAndUID() {
        let speakers = AudioDevice(
            objectID: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
            transport: .builtIn, hasInput: false, hasOutput: true, isAlive: true, portLabel: "Built-in"
        )
        let hdmi = AudioDevice(
            objectID: 2, uid: "09D1667F-0000-0000-1F1E-010380462778", name: "BenQ EX3203R",
            transport: .display, hasInput: false, hasOutput: true, isAlive: true, portLabel: "HDMI"
        )
        let dp1 = AudioDevice(
            objectID: 3, uid: "09D1667F-0000-0000-1F1E-0104C58B4E78", name: "BenQ EX3203R",
            transport: .display, hasInput: false, hasOutput: true, isAlive: true, portLabel: "DisplayPort"
        )
        let labels = AudioDevice.disambiguatedNames(for: [speakers, hdmi, dp1])
        XCTAssertEqual(labels[speakers.uid], "MacBook Pro Speakers")
        XCTAssertEqual(labels[hdmi.uid], "BenQ EX3203R (HDMI)")
        XCTAssertEqual(labels[dp1.uid], "BenQ EX3203R (DisplayPort)")

        let dp2 = AudioDevice(
            objectID: 4, uid: "09D1667F-0000-0000-1F1E-0104C58B99AA", name: "BenQ EX3203R",
            transport: .display, hasInput: false, hasOutput: true, isAlive: true, portLabel: "DisplayPort"
        )
        let samePortLabels = AudioDevice.disambiguatedNames(for: [dp1, dp2])
        XCTAssertEqual(samePortLabels[dp1.uid], "BenQ EX3203R (DisplayPort · 4E78)")
        XCTAssertEqual(samePortLabels[dp2.uid], "BenQ EX3203R (DisplayPort · 99AA)")
    }

    /// Regression test: `MenuBarExtra(.window)` queries `sizeThatFits(in: .zero)`
    /// while `devices` starts empty and populates asynchronously. The device list
    /// must never collapse to a zero-height `ScrollView`.
    @MainActor
    func testMenuContentViewNeverCollapsesWhenDevicesPopulateAsynchronously() async throws {
        let suite = "AudioIOKeeperTests-PopoverLayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let worker = FakeAudioHardwareWorker()
        let model = AppModel(
            worker: worker, settings: SettingsStore(defaults: defaults), loginItem: FakeLoginItemManager()
        )
        defer { model.stop() }

        let controller = NSHostingController(rootView: MenuContentView().environment(model))
        controller.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        let emptyHeight = controller.sizeThatFits(in: .zero).height

        worker.devices = [
            AudioDevice(objectID: 1, uid: "s1", name: "Speakers", transport: .builtIn,
                        hasInput: false, hasOutput: true, isAlive: true),
            AudioDevice(objectID: 2, uid: "b1", name: "BenQ EX3203R", transport: .display,
                        hasInput: false, hasOutput: true, isAlive: true, portLabel: "HDMI"),
            AudioDevice(objectID: 3, uid: "b2", name: "BenQ EX3203R", transport: .display,
                        hasInput: false, hasOutput: true, isAlive: true, portLabel: "DisplayPort"),
            AudioDevice(objectID: 4, uid: "ap-out", name: "AirPods", transport: .bluetooth,
                        hasInput: false, hasOutput: true, isAlive: true),
            AudioDevice(objectID: 5, uid: "usb", name: "USB Mic", transport: .usb,
                        hasInput: true, hasOutput: true, isAlive: true),
            AudioDevice(objectID: 6, uid: "ap-in", name: "AirPods", transport: .bluetooth,
                        hasInput: true, hasOutput: false, isAlive: true),
            AudioDevice(objectID: 7, uid: "mbp-mic", name: "MacBook Mic", transport: .builtIn,
                        hasInput: true, hasOutput: false, isAlive: true),
            AudioDevice(objectID: 8, uid: "ip-mic", name: "iPhone Mic", transport: .continuity,
                        hasInput: true, hasOutput: false, isAlive: true)
        ]
        worker.setSystemDefault("s1", for: .output)
        worker.setSystemDefault("mbp-mic", for: .input)
        model.start()
        for _ in 0..<50 where model.devices.count < 8 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.devices.count, 8)

        controller.view.layoutSubtreeIfNeeded()
        let populatedHeight = controller.sizeThatFits(in: .zero).height
        XCTAssertGreaterThan(
            populatedHeight, emptyHeight + 220,
            "popover minimum height must expand to show all 9 device rows instead of collapsing"
        )
    }

    @MainActor
    func testSlowWakingDeviceIsRestoredByPostWakeFollowUpScan() async throws {
        let suite = "AudioIOKeeperTests-SlowWake-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let worker = FakeAudioHardwareWorker()
        let speakers = AudioDevice(objectID: 1, uid: "speakers", name: "Speakers", transport: .builtIn,
                                   hasInput: false, hasOutput: true, isAlive: true)
        let display = AudioDevice(objectID: 2, uid: "dp-mon", name: "BenQ EX3203R", transport: .display,
                                  hasInput: false, hasOutput: true, isAlive: true, portLabel: "DisplayPort")
        worker.devices = [speakers, display]
        worker.setSystemDefault("dp-mon", for: .output)

        let model = AppModel(
            worker: worker, settings: SettingsStore(defaults: defaults), loginItem: FakeLoginItemManager()
        )
        defer { model.stop() }
        model.start()
        for _ in 0..<50 where model.pinnedUID(for: .output) != "dp-mon" {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Simulate sleep/wake where DisplayPort audio is temporarily absent at wake
        // and re-enumerates 200 ms later without emitting a HAL ping.
        worker.devices = [speakers]
        worker.setSystemDefault("speakers", for: .output)
        model.handleSystemWake()
        try await Task.sleep(for: .milliseconds(200))
        worker.devices = [speakers, display]

        for _ in 0..<250 where model.currentUID(for: .output) != "dp-mon" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(worker.systemDefault(for: .output), "dp-mon")
        XCTAssertEqual(model.currentUID(for: .output), "dp-mon")
    }
}
