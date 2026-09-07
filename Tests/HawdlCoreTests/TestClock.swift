import Foundation

/// Hand-cranked clock so the engine tests never sleep.
final class TestClock {
    private(set) var now: Date

    init(start: Date = Date(timeIntervalSince1970: 1_757_240_625)) {
        self.now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
