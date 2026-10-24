import Foundation

/// When to refresh next: the normal interval after a good refresh, exponential backoff after failures.
public struct RefreshSchedule: Equatable, Sendable {
    public var interval: TimeInterval
    /// First retry delay after a failed refresh. Doubles with each further failure, capped at `interval`.
    public var initialRetry: TimeInterval

    public init(interval: TimeInterval = 30 * 60, initialRetry: TimeInterval = 60) {
        self.interval = interval
        self.initialRetry = initialRetry
    }

    public func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(interval, initialRetry * pow(2, Double(min(failures - 1, 30))))
    }
}
