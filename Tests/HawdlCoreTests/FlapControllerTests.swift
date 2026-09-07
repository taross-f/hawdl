import XCTest
@testable import HawdlCore

final class FlapControllerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_757_240_625)

    func testActsImmediatelyBelowTheThreshold() {
        var flaps = FlapController(window: 10, threshold: 5)
        for offset in 0..<4 {
            XCTAssertNil(flaps.record(at: epoch.addingTimeInterval(Double(offset) * 0.1)))
        }
        XCTAssertEqual(flaps.windowedCount, 4)
    }

    func testBacksOffOnceTheThresholdIsReachedInsideTheWindow() {
        var flaps = FlapController(window: 10, threshold: 5)
        for offset in 0..<4 {
            XCTAssertNil(flaps.record(at: epoch.addingTimeInterval(Double(offset) * 0.1)))
        }
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(0.4)), 1)
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(0.5)), 2)
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(0.6)), 4)
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(0.7)), 8)
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(0.8)), 16)
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(0.9)), 30)
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(1.0)), 30)
    }

    func testSlowFlapsNeverBackOff() {
        var flaps = FlapController(window: 10, threshold: 5)
        // One flap every 11 seconds: outside the window, so never a storm.
        for step in 0..<50 {
            XCTAssertNil(
                flaps.record(at: epoch.addingTimeInterval(Double(step) * 11)),
                "step \(step)"
            )
        }
    }

    func testQuietPeriodResetsTheBackoffLevel() {
        var flaps = FlapController(window: 10, threshold: 5)
        for offset in 0..<5 {
            _ = flaps.record(at: epoch.addingTimeInterval(Double(offset) * 0.1))
        }
        XCTAssertGreaterThan(flaps.backoffLevel, 0)

        // A full window with nothing in it, then a fresh storm.
        for offset in 0..<4 {
            XCTAssertNil(flaps.record(at: epoch.addingTimeInterval(100 + Double(offset) * 0.1)))
        }
        XCTAssertEqual(flaps.record(at: epoch.addingTimeInterval(100.4)), 1,
                       "the exponent should start over after a quiet window")
    }

    /// Regression test for the sawtooth: once the delay grows past the window,
    /// consecutive flaps land outside the window and a naive sliding counter
    /// would empty out and drop straight back into fast retries.
    func testStormSurvivesDelaysLongerThanTheWindow() {
        var flaps = FlapController(window: 10, threshold: 5, base: 1, cap: 30)
        var time = epoch
        for _ in 0..<5 {
            _ = flaps.record(at: time)
            time = time.addingTimeInterval(0.1)
        }
        XCTAssertTrue(flaps.isStorming)

        // Behave like the daemon: wait out each delay, get flapped again 10ms
        // after we put the interface back down.
        var delays: [TimeInterval] = []
        for _ in 0..<20 {
            guard let delay = flaps.record(at: time) else {
                return XCTFail("the storm ended even though the OS never stopped")
            }
            delays.append(delay)
            time = time.addingTimeInterval(delay + 0.01)
        }

        XCTAssertEqual(Array(delays.suffix(5)), [30, 30, 30, 30, 30])
        XCTAssertEqual(flaps.windowedCount, 1, "only the newest flap is inside the window by now")
    }

    func testStormEndsAfterTheInterfaceGoesQuiet() {
        var flaps = FlapController(window: 10, threshold: 5, base: 1, cap: 30)
        var time = epoch
        for _ in 0..<12 {
            _ = flaps.record(at: time)
            time = time.addingTimeInterval(0.1)
        }
        XCTAssertTrue(flaps.isStorming)

        // window (10s) + the last delay (30s) of silence ends it.
        XCTAssertNil(flaps.record(at: time.addingTimeInterval(41)))
        XCTAssertFalse(flaps.isStorming)
    }

    func testResetClearsEverything() {
        var flaps = FlapController(window: 10, threshold: 5)
        for offset in 0..<6 {
            _ = flaps.record(at: epoch.addingTimeInterval(Double(offset) * 0.1))
        }
        flaps.reset()
        XCTAssertEqual(flaps.windowedCount, 0)
        XCTAssertEqual(flaps.backoffLevel, 0)
        XCTAssertNil(flaps.record(at: epoch.addingTimeInterval(1)))
    }
}
