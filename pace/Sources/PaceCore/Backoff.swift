import Foundation

public enum Backoff {
    /// Delay before the next attempt after `failures` consecutive failures: the base interval,
    /// doubled per extra failure, capped. A server `Retry-After` wins when it is longer.
    public static func delay(failures: Int, base: TimeInterval, cap: TimeInterval = 1800, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let exponent = Double(max(0, failures - 1))
        let doubled = min(cap, base * pow(2, exponent))
        if let retryAfter { return min(cap, max(doubled, retryAfter)) }
        return doubled
    }
}
