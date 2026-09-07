import Foundation

/// Decides when the OS is fighting us hard enough that we should stop swinging.
///
/// Entering a storm takes `threshold` unwanted `up` transitions inside
/// `window`. Leaving one takes a genuinely quiet stretch: `window` seconds on
/// top of however long we last made the OS wait.
///
/// That second rule matters. A plain sliding window is not enough, because once
/// the backoff delay grows past the window, consecutive flaps land outside the
/// window, the counter empties, and the daemon drops straight back into fast
/// retries — a sawtooth that defeats the point of backing off at all.
public struct FlapController: Equatable, Sendable {
    public let window: TimeInterval
    public let threshold: Int
    public let base: TimeInterval
    public let cap: TimeInterval

    private var recent: [Date] = []
    private var lastFlap: Date?
    private var level: Int = 0

    public init(
        window: TimeInterval = 10,
        threshold: Int = 5,
        base: TimeInterval = 1,
        cap: TimeInterval = 30
    ) {
        self.window = window
        self.threshold = max(1, threshold)
        self.base = base
        self.cap = cap
    }

    /// Number of flaps currently inside the window. Exposed for tests.
    public var windowedCount: Int { recent.count }

    /// Current backoff exponent: 0 when no storm is in progress.
    public var backoffLevel: Int { level }

    public var isStorming: Bool { level > 0 }

    /// Records one unwanted `up`.
    ///
    /// - Returns: `nil` to act immediately, or the number of seconds to wait
    ///   before the next attempt.
    public mutating func record(at now: Date) -> TimeInterval? {
        if let lastFlap, now.timeIntervalSince(lastFlap) > quietPeriod {
            recent.removeAll()
            level = 0
        }
        lastFlap = now

        let cutoff = now.addingTimeInterval(-window)
        recent.removeAll { $0 < cutoff }
        recent.append(now)

        guard level > 0 || recent.count >= threshold else { return nil }

        let delay = Backoff.delay(forLevel: level, base: base, cap: cap)
        level += 1
        return delay
    }

    /// Forgets the storm entirely (used when the desired state changes).
    public mutating func reset() {
        recent.removeAll()
        lastFlap = nil
        level = 0
    }

    /// How long the interface must stay put before we call the storm over:
    /// a full window on top of the delay we last imposed.
    private var quietPeriod: TimeInterval {
        guard level > 0 else { return window }
        return window + Backoff.delay(forLevel: level - 1, base: base, cap: cap)
    }
}
