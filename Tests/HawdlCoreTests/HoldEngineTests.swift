import XCTest
@testable import HawdlCore

final class HoldEngineTests: XCTestCase {
    private var clock = TestClock()

    private func makeEngine(
        state: InterfaceState = .up,
        desired: DesiredState = .release,
        config: HoldEngine.Config = .default
    ) -> (HoldEngine, FakeInterfaceController) {
        let clock = TestClock()
        self.clock = clock
        let fake = FakeInterfaceController(state: state)
        let engine = HoldEngine(
            controller: fake,
            config: config,
            desired: desired,
            now: { clock.now }
        )
        return (engine, fake)
    }

    func testHoldingBringsTheInterfaceDownImmediately() {
        let (engine, fake) = makeEngine(state: .up)
        _ = engine.handle(.enforce)
        XCTAssertEqual(fake.bringDownCallCount, 0, "release must not touch the interface")

        let outcome = engine.setDesired(.hold)
        XCTAssertEqual(outcome.action, .bringDown)
        XCTAssertEqual(fake.state, .down)
        XCTAssertEqual(outcome.status.actual, .down)
        XCTAssertEqual(outcome.status.desired, .hold)
    }

    func testUnsolicitedUpIsPushedBackDownAndCounted() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        XCTAssertEqual(engine.flapCount, 0, "the first enforcement is not a flap")

        fake.state = .up
        let outcome = engine.handle(.interfaceEvent)
        XCTAssertEqual(outcome.action, .bringDown)
        XCTAssertEqual(fake.state, .down)
        XCTAssertEqual(engine.flapCount, 1)
        XCTAssertEqual(engine.lastFlapAt, clock.now)
    }

    func testReconcileCatchesAnUpWeNeverGotAnEventFor() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)

        fake.state = .up
        let outcome = engine.handle(.reconcileTick)
        XCTAssertEqual(outcome.action, .bringDown)
        XCTAssertEqual(engine.flapCount, 1)
    }

    func testReleaseBringsTheInterfaceBackUp() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        XCTAssertEqual(fake.state, .down)

        let outcome = engine.setDesired(.release)
        XCTAssertEqual(outcome.action, .bringUp)
        XCTAssertEqual(fake.state, .up)
    }

    func testReleaseDoesNotKeepRaisingTheInterface() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        _ = engine.setDesired(.release)

        // Wi-Fi goes off; awdl0 goes down on its own. Not our business.
        fake.state = .down
        XCTAssertEqual(engine.handle(.interfaceEvent).action, .none)
        XCTAssertEqual(engine.handle(.reconcileTick).action, .none)
        XCTAssertEqual(fake.state, .down)
    }

    func testShutdownAlwaysRestoresTheInterface() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        XCTAssertEqual(fake.state, .down)

        let outcome = engine.handle(.shutdown)
        XCTAssertEqual(outcome.action, .bringUp)
        XCTAssertEqual(fake.state, .up)
    }

    func testMissingInterfaceIsReportedAsUnavailableAndIdles() {
        let (engine, fake) = makeEngine(state: .unavailable, desired: .hold)
        let outcome = engine.handle(.enforce)
        XCTAssertEqual(outcome.action, .none)
        XCTAssertEqual(outcome.status.actual, .unavailable)
        XCTAssertFalse(outcome.status.available)
        XCTAssertEqual(fake.setUpCallCount, 0)

        // ...and it keeps idling rather than erroring out.
        for trigger in [Trigger.interfaceEvent, .reconcileTick, .shutdown] {
            XCTAssertEqual(engine.handle(trigger).action, .none)
        }
    }

    func testUnreadableInterfaceIsReportedAsUnknownAndIdles() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        fake.isUpError = .permissionDenied

        let outcome = engine.handle(.interfaceEvent)
        XCTAssertEqual(outcome.status.actual, .unknown)
        XCTAssertEqual(outcome.action, .none)
        XCTAssertEqual(fake.bringDownCallCount, 0)
    }

    func testAFailedWriteIsReportedButNotFatal() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        fake.setUpError = .permissionDenied

        let outcome = engine.handle(.enforce)
        XCTAssertEqual(outcome.action, .bringDown)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(fake.state, .up, "the write failed, so nothing changed")

        // The next trigger still tries again.
        XCTAssertEqual(engine.handle(.reconcileTick).action, .bringDown)
        XCTAssertEqual(fake.state, .down)
    }

    func testStatusChangedOnlyFiresOnRealChanges() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        XCTAssertTrue(engine.handle(.enforce).statusChanged, "the first status is always new")
        XCTAssertFalse(engine.handle(.reconcileTick).statusChanged)
        XCTAssertFalse(engine.handle(.reconcileTick).statusChanged)

        fake.state = .up
        XCTAssertTrue(engine.handle(.interfaceEvent).statusChanged, "flapCount moved")
    }

    func testSwitchingDesiredStateClearsAnyBackoff() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        for _ in 0..<6 {
            fake.state = .up
            _ = engine.handle(.interfaceEvent)
            clock.advance(by: 0.05)
        }
        XCTAssertTrue(engine.backoffPending)

        _ = engine.setDesired(.release)
        XCTAssertFalse(engine.backoffPending)

        _ = engine.setDesired(.hold)
        XCTAssertFalse(engine.backoffPending)
        fake.state = .up
        // The fresh hold reacts immediately instead of inheriting the old storm.
        XCTAssertEqual(engine.handle(.interfaceEvent).action, .bringDown)
    }

    /// The control socket is world-writable, so re-sending `hold` must not be a
    /// way to make the daemon abandon its backoff and fight the OS flat out.
    func testReassertingTheSameStateDoesNotResetTheBackoff() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        for _ in 0..<6 {
            fake.state = .up
            _ = engine.handle(.interfaceEvent)
            clock.advance(by: 0.05)
        }
        XCTAssertTrue(engine.backoffPending)
        let writesSoFar = fake.bringDownCallCount

        for _ in 0..<50 {
            _ = engine.setDesired(.hold)
        }
        XCTAssertTrue(engine.backoffPending)
        XCTAssertEqual(fake.bringDownCallCount, writesSoFar,
                       "re-asserting hold should not have produced any new writes")
    }

    func testFlapCountAndTimestampAreExposedToClients() {
        let (engine, fake) = makeEngine(state: .up, desired: .hold)
        _ = engine.handle(.enforce)
        XCTAssertNil(engine.status().lastFlapAt)

        clock.advance(by: 5)
        fake.state = .up
        let status = engine.handle(.interfaceEvent).status
        XCTAssertEqual(status.flapCount, 1)
        XCTAssertEqual(status.lastFlapAt, clock.now)
        XCTAssertEqual(status.daemonVersion, hawdlVersion)
    }
}
