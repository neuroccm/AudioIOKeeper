import AppKit
import XCTest
@testable import AudioIOKeeper

/// Guards against invented SF Symbol names.
///
/// `Image(systemName:)` silently renders nothing for a name that does not
/// exist, and in a `MenuBarExtra` label that collapses the menu bar item
/// to zero width — the app looks like it quit while it keeps running.
/// The keeping state shipped that way (`waveform.badge.lock` exists in no
/// macOS release), so every symbol name the app can pick at runtime is
/// asserted to resolve to a real image here.
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
}
