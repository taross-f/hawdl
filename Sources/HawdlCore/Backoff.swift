import Foundation

/// Exponential backoff: 1s, 2s, 4s, ... clamped to a ceiling.
public enum Backoff {
    /// Highest exponent we will compute. 2^62 seconds already dwarfs any
    /// sensible ceiling; clamping keeps `pow` away from infinity.
    static let maxLevel = 62

    /// - Parameter level: 0 for the first backoff, 1 for the second, and so on.
    public static func delay(
        forLevel level: Int,
        base: TimeInterval = 1,
        cap: TimeInterval = 30
    ) -> TimeInterval {
        guard base > 0 else { return 0 }
        let clamped = min(max(level, 0), maxLevel)
        let scaled = base * pow(2.0, Double(clamped))
        return min(scaled, cap)
    }
}
