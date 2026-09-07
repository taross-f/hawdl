import XCTest
@testable import HawdlCore

/// Enumerates the `desired x actual x trigger -> action` table.
final class StateMachineTests: XCTestCase {

    private func action(
        _ desired: DesiredState,
        _ observed: InterfaceState,
        _ trigger: Trigger,
        backoffPending: Bool = false
    ) -> Action {
        StateMachine.action(
            for: .init(
                desired: desired,
                observed: observed,
                trigger: trigger,
                backoffPending: backoffPending
            )
        )
    }

    func testHoldingBringsAnUpInterfaceDown() {
        for trigger in [Trigger.enforce, .interfaceEvent, .reconcileTick, .backoffExpired, .desiredChanged] {
            XCTAssertEqual(action(.hold, .up, trigger), .bringDown, "trigger: \(trigger)")
        }
    }

    func testHoldingLeavesADownInterfaceAlone() {
        for trigger in [Trigger.enforce, .interfaceEvent, .reconcileTick, .backoffExpired, .desiredChanged] {
            XCTAssertEqual(action(.hold, .down, trigger), .none, "trigger: \(trigger)")
        }
    }

    func testReleaseRaisesTheInterfaceOnlyOnTheTransition() {
        XCTAssertEqual(action(.release, .down, .desiredChanged), .bringUp)
        // Afterwards we keep our hands off: awdl0 being down while Wi-Fi is off
        // is normal and not ours to correct.
        XCTAssertEqual(action(.release, .down, .interfaceEvent), .none)
        XCTAssertEqual(action(.release, .down, .reconcileTick), .none)
        XCTAssertEqual(action(.release, .down, .enforce), .none)
        XCTAssertEqual(action(.release, .up, .desiredChanged), .none)
    }

    func testShutdownAlwaysHandsTheInterfaceBack() {
        XCTAssertEqual(action(.hold, .down, .shutdown), .bringUp)
        XCTAssertEqual(action(.release, .down, .shutdown), .bringUp)
        XCTAssertEqual(action(.hold, .up, .shutdown), .none)
        XCTAssertEqual(action(.release, .up, .shutdown), .none)
    }

    func testUnavailableInterfaceIsNeverTouched() {
        for desired in [DesiredState.hold, .release] {
            for trigger in Trigger.allCases {
                XCTAssertEqual(action(desired, .unavailable, trigger), .none,
                               "\(desired) / \(trigger)")
                XCTAssertEqual(action(desired, .unknown, trigger), .none,
                               "\(desired) / \(trigger)")
            }
        }
    }

    func testPendingBackoffSuppressesRoutineTriggers() {
        XCTAssertEqual(action(.hold, .up, .interfaceEvent, backoffPending: true), .none)
        XCTAssertEqual(action(.hold, .up, .reconcileTick, backoffPending: true), .none)
        XCTAssertEqual(action(.hold, .up, .enforce, backoffPending: true), .none)
    }

    func testPendingBackoffDoesNotSuppressTheRetryOrTheUser() {
        XCTAssertEqual(action(.hold, .up, .backoffExpired, backoffPending: true), .bringDown)
        XCTAssertEqual(action(.hold, .up, .desiredChanged, backoffPending: true), .bringDown)
        XCTAssertEqual(action(.hold, .down, .shutdown, backoffPending: true), .bringUp)
    }

    /// Every combination must produce an answer, and the table must be total.
    func testTableIsTotalAndDeterministic() {
        var seen = 0
        for desired in [DesiredState.hold, .release] {
            for observed in [InterfaceState.up, .down, .unavailable, .unknown] {
                for trigger in Trigger.allCases {
                    for pending in [false, true] {
                        let input = StateMachine.Input(
                            desired: desired,
                            observed: observed,
                            trigger: trigger,
                            backoffPending: pending
                        )
                        XCTAssertEqual(StateMachine.action(for: input), StateMachine.action(for: input))
                        seen += 1
                    }
                }
            }
        }
        XCTAssertEqual(seen, 2 * 4 * Trigger.allCases.count * 2)
    }

    /// We must never raise an interface the user asked us to hold down.
    func testHoldNeverBringsTheInterfaceUpExceptOnShutdown() {
        for observed in [InterfaceState.up, .down, .unavailable, .unknown] {
            for trigger in Trigger.allCases where trigger != .shutdown {
                for pending in [false, true] {
                    XCTAssertNotEqual(
                        action(.hold, observed, trigger, backoffPending: pending),
                        .bringUp,
                        "\(observed) / \(trigger) / pending=\(pending)"
                    )
                }
            }
        }
    }
}
