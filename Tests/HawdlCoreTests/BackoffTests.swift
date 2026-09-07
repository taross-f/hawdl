import XCTest
@testable import HawdlCore

final class BackoffTests: XCTestCase {
    func testDoublesFromTheBaseDelay() {
        XCTAssertEqual(Backoff.delay(forLevel: 0), 1)
        XCTAssertEqual(Backoff.delay(forLevel: 1), 2)
        XCTAssertEqual(Backoff.delay(forLevel: 2), 4)
        XCTAssertEqual(Backoff.delay(forLevel: 3), 8)
        XCTAssertEqual(Backoff.delay(forLevel: 4), 16)
    }

    func testClampsToTheCeiling() {
        XCTAssertEqual(Backoff.delay(forLevel: 5), 30)
        XCTAssertEqual(Backoff.delay(forLevel: 6), 30)
        XCTAssertEqual(Backoff.delay(forLevel: 1_000), 30)
        XCTAssertEqual(Backoff.delay(forLevel: Int.max), 30)
    }

    func testNegativeLevelsAreTreatedAsTheFirstAttempt() {
        XCTAssertEqual(Backoff.delay(forLevel: -1), 1)
        XCTAssertEqual(Backoff.delay(forLevel: Int.min), 1)
    }

    func testHonoursCustomBaseAndCap() {
        XCTAssertEqual(Backoff.delay(forLevel: 0, base: 0.25, cap: 2), 0.25)
        XCTAssertEqual(Backoff.delay(forLevel: 2, base: 0.25, cap: 2), 1)
        XCTAssertEqual(Backoff.delay(forLevel: 8, base: 0.25, cap: 2), 2)
    }

    func testDelayIsNeverNegativeOrInfinite() {
        for level in [0, 1, 10, 62, 63, 100, Int.max] {
            let delay = Backoff.delay(forLevel: level)
            XCTAssertTrue(delay.isFinite, "level \(level)")
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, 30)
        }
    }
}
