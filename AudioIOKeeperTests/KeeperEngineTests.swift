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

final class RestoreThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testImmediateBudgetIsAllowed() {
        var throttle = RestoreThrottle()
        for _ in 0..<RestoreThrottle.immediateBudget {
            XCTAssertEqual(throttle.decision(now: t0), .allow)
            throttle.recordRestore(at: t0)
        }
    }

    func testBudgetExhaustionEntersCooldown() {
        var throttle = RestoreThrottle()
        for _ in 0..<RestoreThrottle.immediateBudget {
            throttle.recordRestore(at: t0)
        }
        let expected = t0.addingTimeInterval(RestoreThrottle.baseCooldown)
        XCTAssertEqual(throttle.decision(now: t0), .cooldown(until: expected))
        // Still cooling down just before the deadline.
        let during = t0.addingTimeInterval(RestoreThrottle.baseCooldown - 0.1)
        XCTAssertEqual(throttle.decision(now: during), .cooldown(until: expected))
        XCTAssertTrue(throttle.isConflicting(now: t0))
    }

    func testExactlyOneRetryAfterCooldownThenLongerCooldown() {
        var throttle = RestoreThrottle()
        for _ in 0..<RestoreThrottle.immediateBudget {
            throttle.recordRestore(at: t0)
        }
        _ = throttle.decision(now: t0) // arm first cooldown

        let afterFirst = t0.addingTimeInterval(RestoreThrottle.baseCooldown + 0.1)
        XCTAssertEqual(throttle.decision(now: afterFirst), .allow, "one retry once the cooldown is served")
        throttle.recordRestore(at: afterFirst)

        // Next ask is held back for twice as long (exponential growth).
        let expected = afterFirst.addingTimeInterval(RestoreThrottle.baseCooldown * 2)
        XCTAssertEqual(throttle.decision(now: afterFirst), .cooldown(until: expected))
    }

    func testCooldownIsCapped() {
        var throttle = RestoreThrottle()
        for _ in 0..<30 { throttle.recordRestore(at: t0) }
        // Far over budget within the window would need prune-safe history;
        // simulate instead by arming through repeated allow/record cycles.
        var time = t0
        var lastCooldown: TimeInterval = 0
        for _ in 0..<12 {
            switch throttle.decision(now: time) {
            case .allow:
                throttle.recordRestore(at: time)
            case .cooldown(let until):
                lastCooldown = until.timeIntervalSince(time)
                time = until.addingTimeInterval(0.1)
                // Keep restores inside the counting window.
                if time.timeIntervalSince(t0) > RestoreThrottle.window - 1 { break }
            }
        }
        XCTAssertLessThanOrEqual(lastCooldown, RestoreThrottle.maxCooldown)
    }

    func testQuietPeriodResetsHistory() {
        var throttle = RestoreThrottle()
        for _ in 0..<RestoreThrottle.immediateBudget {
            throttle.recordRestore(at: t0)
        }
        _ = throttle.decision(now: t0)
        let later = t0.addingTimeInterval(RestoreThrottle.quietReset + 1)
        throttle.recordStableObservation(at: later)
        XCTAssertFalse(throttle.isConflicting(now: later))
        XCTAssertEqual(throttle.decision(now: later), .allow)
    }

    func testResetClearsConflict() {
        var throttle = RestoreThrottle()
        for _ in 0..<RestoreThrottle.immediateBudget {
            throttle.recordRestore(at: t0)
        }
        _ = throttle.decision(now: t0)
        throttle.reset()
        XCTAssertFalse(throttle.isConflicting(now: t0))
        XCTAssertEqual(throttle.decision(now: t0), .allow)
    }

    /// Long-duration simulated clock: a competitor switches the pin away
    /// immediately after every restore for a full simulated hour, crossing
    /// many rolling-window boundaries. Backoff must be monotonic, reach
    /// the cap, and hold it — deriving the exponent from the in-window
    /// restore count regressed to 2–32 s cooldowns (294 restores/hour,
    /// cap never reached) because old attempts expired from the window
    /// while the conflict was still unresolved.
    func testSustainedConflictEscalatesToCapAndHoldsIt() {
        var throttle = RestoreThrottle()
        var now = t0
        let end = t0.addingTimeInterval(3_600)
        var cooldowns: [TimeInterval] = []
        var restores = 0
        while now < end {
            switch throttle.decision(now: now) {
            case .allow:
                throttle.recordRestore(at: now)
                restores += 1
                now = now.addingTimeInterval(0.05) // notification debounce
            case .cooldown(let until):
                cooldowns.append(until.timeIntervalSince(now))
                now = until // retry exactly when the cooldown expires
            }
        }
        XCTAssertEqual(Array(cooldowns.prefix(6)), [2, 4, 8, 16, 32, 60])
        XCTAssertTrue(
            cooldowns.dropFirst(6).allSatisfy { $0 == RestoreThrottle.maxCooldown },
            "once the cap is reached it must hold for the rest of the conflict: \(cooldowns)"
        )
        XCTAssertTrue(zip(cooldowns, cooldowns.dropFirst()).allSatisfy { $0 <= $1 },
                      "cooldowns must never shrink during an unresolved conflict")
        XCTAssertLessThan(restores, 100,
                          "a capped 60 s retry rate bounds the hour to ~70 restores, got \(restores)")
        XCTAssertTrue(throttle.isConflicting(now: now))
    }

    /// Escalation is per-episode: after a verified stable period the next
    /// exhaustion starts again from the base cooldown, not the old level.
    func testEscalationResetsAfterStablePeriod() {
        var throttle = RestoreThrottle()
        for _ in 0..<RestoreThrottle.immediateBudget {
            throttle.recordRestore(at: t0)
        }
        _ = throttle.decision(now: t0) // arm 2 s
        let firstRetry = t0.addingTimeInterval(3)
        XCTAssertEqual(throttle.decision(now: firstRetry), .allow)
        throttle.recordRestore(at: firstRetry)
        XCTAssertEqual(
            throttle.decision(now: firstRetry),
            .cooldown(until: firstRetry.addingTimeInterval(4)),
            "second cooldown in the same episode doubles"
        )

        let later = firstRetry.addingTimeInterval(RestoreThrottle.quietReset + 1)
        throttle.recordStableObservation(at: later)
        XCTAssertEqual(throttle.escalationLevel, 0)
        for _ in 0..<RestoreThrottle.immediateBudget {
            throttle.recordRestore(at: later)
        }
        XCTAssertEqual(
            throttle.decision(now: later),
            .cooldown(until: later.addingTimeInterval(RestoreThrottle.baseCooldown)),
            "a new episode after a stable period starts from the base cooldown again"
        )
    }

    func testConflictStatusSurfaces() {
        let status = DirectionStatus.status(
            keepingEnabled: true,
            pinnedUID: "speakers",
            currentUID: "airpods",
            availableUIDs: ["speakers", "airpods"],
            inConflict: true
        )
        XCTAssertEqual(status, .conflicted)
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

    /// A deliberate pause outranks drift/conflict reporting: the user asked
    /// for switching to be left alone, so nothing about it is a problem.
    func testPausedStatusWhileKeepingOn() {
        let status = DirectionStatus.status(
            keepingEnabled: true,
            pinnedUID: "speakers",
            currentUID: "airpods",
            availableUIDs: ["speakers", "airpods"],
            isPaused: true
        )
        XCTAssertEqual(status, .paused)
    }

    /// With keeping off the pause is irrelevant; "off" is the fuller truth.
    func testNotKeepingOutranksPaused() {
        let status = DirectionStatus.status(
            keepingEnabled: false,
            pinnedUID: "speakers",
            currentUID: "airpods",
            availableUIDs: ["speakers", "airpods"],
            isPaused: true
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
