import XCTest
@testable import AudioIOKeeper

final class KeeperEngineTests: XCTestCase {

    func testRestoresPinWhenSystemSwitchesAway() {
        let action = KeeperEngine.action(
            keepingEnabled: true,
            pinnedUID: "speakers",
            currentUID: "airpods",
            availableUIDs: ["speakers", "airpods"]
        )
        XCTAssertEqual(action, .restore(uid: "speakers"))
    }

    func testNoActionWhenPinAlreadyCurrent() {
        let action = KeeperEngine.action(
            keepingEnabled: true,
            pinnedUID: "speakers",
            currentUID: "speakers",
            availableUIDs: ["speakers"]
        )
        XCTAssertEqual(action, .none)
    }

    func testNoActionWhenKeepingDisabled() {
        let action = KeeperEngine.action(
            keepingEnabled: false,
            pinnedUID: "speakers",
            currentUID: "airpods",
            availableUIDs: ["speakers", "airpods"]
        )
        XCTAssertEqual(action, .none)
    }

    func testNoActionWithoutPin() {
        let action = KeeperEngine.action(
            keepingEnabled: true,
            pinnedUID: nil,
            currentUID: "airpods",
            availableUIDs: ["airpods"]
        )
        XCTAssertEqual(action, .none)
    }

    /// A disconnected pinned device must never cause thrashing or an attempt
    /// to select a device that does not exist; the keeper waits for it.
    func testNoActionWhenPinnedDeviceDisconnected() {
        let action = KeeperEngine.action(
            keepingEnabled: true,
            pinnedUID: "usb-interface",
            currentUID: "built-in",
            availableUIDs: ["built-in"]
        )
        XCTAssertEqual(action, .none)
    }

    func testRestoresWhenCurrentDefaultIsUnknown() {
        let action = KeeperEngine.action(
            keepingEnabled: true,
            pinnedUID: "speakers",
            currentUID: nil,
            availableUIDs: ["speakers"]
        )
        XCTAssertEqual(action, .restore(uid: "speakers"))
    }
}

final class DirectionStatusTests: XCTestCase {

    func testWaitingWhenPinnedDeviceGone() {
        let status = DirectionStatus.status(
            keepingEnabled: true,
            pinnedUID: "usb-interface",
            currentUID: "built-in",
            availableUIDs: ["built-in"]
        )
        XCTAssertEqual(status, .waitingForPinnedDevice)
    }

    func testKeptWhenPinIsCurrent() {
        let status = DirectionStatus.status(
            keepingEnabled: true,
            pinnedUID: "speakers",
            currentUID: "speakers",
            availableUIDs: ["speakers"]
        )
        XCTAssertEqual(status, .kept)
    }

    func testNotKeepingWhenDisabled() {
        let status = DirectionStatus.status(
            keepingEnabled: false,
            pinnedUID: "speakers",
            currentUID: "airpods",
            availableUIDs: ["speakers", "airpods"]
        )
        XCTAssertEqual(status, .notKeeping)
    }

    func testNoPinSelected() {
        let status = DirectionStatus.status(
            keepingEnabled: true,
            pinnedUID: nil,
            currentUID: "airpods",
            availableUIDs: ["airpods"]
        )
        XCTAssertEqual(status, .noPinSelected)
    }
}
