import XCTest
@testable import HawdlCore

/// The scenario this whole project exists to survive: macOS deciding it wants
/// awdl0 up, over and over, faster than we can put it down.
///
/// The requirement is not "win the fight" — it is "do not burn a core losing
/// it". These tests bound how many kernel writes a storm can cost us.
final class FlapStormTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_757_240_625)

    /// 100 up events in one second must not become 100 writes.
    func testOneHundredEventsCollapseIntoAHandfulOfWrites() {
        let clock = TestClock(start: epoch)
        let fake = FakeInterfaceController(state: .up)
        let config = HoldEngine.Config.default
        let engine = HoldEngine(
            controller: fake,
            config: config,
            desired: .hold,
            now: { clock.now }
        )

        _ = engine.handle(.enforce)
        XCTAssertEqual(fake.bringDownCallCount, 1)

        var backoffsRequested = 0
        for _ in 0..<100 {
            fake.state = .up
            let outcome = engine.handle(.interfaceEvent)
            if outcome.scheduleRetryAfter != nil { backoffsRequested += 1 }
            clock.advance(by: 0.01)
        }

        XCTAssertLessThanOrEqual(
            fake.bringDownCallCount,
            config.flapThreshold + 1,
            "the backoff should have stopped us after the threshold was crossed"
        )
        XCTAssertGreaterThanOrEqual(backoffsRequested, 1)
        XCTAssertTrue(engine.backoffPending)
        XCTAssertEqual(engine.status().flapCount, config.flapThreshold)
    }

    /// Ten simulated minutes of the OS instantly re-raising awdl0 every single
    /// time we take it down.
    func testTenMinuteStormStaysCheap() {
        let clock = TestClock(start: epoch)
        let fake = FakeInterfaceController(state: .up)
        // The OS wins every round: the interface is back up the moment we
        // finish writing the flags.
        fake.afterSetUp = { [unowned fake] up in
            if !up { fake.state = .up }
        }

        let engine = HoldEngine(
            controller: fake,
            desired: .hold,
            now: { clock.now }
        )

        let deadline = epoch.addingTimeInterval(600)
        var pendingRetry: TimeInterval?
        var iterations = 0
        var delays: [TimeInterval] = []

        while clock.now < deadline && iterations < 100_000 {
            iterations += 1
            let trigger: Trigger
            if let retry = pendingRetry {
                clock.advance(by: retry)
                pendingRetry = nil
                trigger = .backoffExpired
            } else {
                // A route event lands ~10ms after our write.
                clock.advance(by: 0.01)
                trigger = .interfaceEvent
            }
            let outcome = engine.handle(trigger)
            if let delay = outcome.scheduleRetryAfter {
                delays.append(delay)
                pendingRetry = delay
            }
        }

        XCTAssertGreaterThan(fake.bringDownCallCount, 0, "we should still be trying")
        XCTAssertLessThan(
            fake.bringDownCallCount,
            40,
            "600s of fighting collapsed to \(fake.bringDownCallCount) writes; "
                + "the backoff should pin this near 600/cap"
        )
        XCTAssertEqual(delays.last, HoldEngine.Config.default.backoffCap,
                       "a sustained storm must saturate the backoff")
        XCTAssertLessThan(iterations, 200, "the loop should be sleeping, not spinning")
    }

    /// Once macOS stops fighting, the daemon must go back to reacting instantly
    /// rather than staying stuck at a 30 second delay.
    func testBackoffRelaxesAfterTheStormPasses() {
        let clock = TestClock(start: epoch)
        let fake = FakeInterfaceController(state: .up)
        let engine = HoldEngine(controller: fake, desired: .hold, now: { clock.now })

        _ = engine.handle(.enforce)
        for _ in 0..<10 {
            fake.state = .up
            _ = engine.handle(.interfaceEvent)
            clock.advance(by: 0.05)
        }
        XCTAssertTrue(engine.backoffPending)

        // Let the retry fire and then leave the interface alone for a while.
        _ = engine.handle(.backoffExpired)
        XCTAssertFalse(engine.backoffPending)
        clock.advance(by: 120)

        fake.state = .up
        let outcome = engine.handle(.interfaceEvent)
        XCTAssertEqual(outcome.action, .bringDown, "a lone flap after a quiet period is not a storm")
        XCTAssertNil(outcome.scheduleRetryAfter)
        XCTAssertEqual(fake.state, .down)
    }
}
