import Foundation

/// Timing decisions for automatic Finder checks. Manual refreshes bypass this policy.
/// No app-visibility input: Finder may be in use while Immount is in the background.
public enum RefreshPolicy {
    public struct Conditions: Sendable, Equatable {
        public var isConnected: Bool
        public var isAsleep: Bool
        public var networkAvailable: Bool
        public var lowPower: Bool
        public var constrainedNetwork: Bool
        public var expensiveNetwork: Bool

        public init(isConnected: Bool = true, isAsleep: Bool = false, networkAvailable: Bool = true,
                    lowPower: Bool = false, constrainedNetwork: Bool = false, expensiveNetwork: Bool = false) {
            self.isConnected = isConnected
            self.isAsleep = isAsleep
            self.networkAvailable = networkAvailable
            self.lowPower = lowPower
            self.constrainedNetwork = constrainedNetwork
            self.expensiveNetwork = expensiveNetwork
        }
    }

    public static let maximumInterval: TimeInterval = 10 * 60
    public static let healthInterval: TimeInterval = 10 * 60

    /// Nil means automatic work is paused. Slow completed scans and consecutive failures
    /// increase spacing, so asking the extension to check again cannot become a busy loop.
    public static func interval(for conditions: Conditions, consecutiveFailures: Int = 0,
                                lastRefreshDuration: TimeInterval = 0) -> TimeInterval? {
        guard conditions.isConnected, !conditions.isAsleep, conditions.networkAvailable else { return nil }
        let cadence: TimeInterval = conditions.constrainedNetwork || conditions.expensiveNetwork ? 120 : (conditions.lowPower ? 60 : 30)
        let duration = lastRefreshDuration.isFinite ? max(0, lastRefreshDuration) : maximumInterval
        let base = max(cadence, min(maximumInterval, duration * 2))
        let exponent = min(5, max(0, consecutiveFailures))
        return min(maximumInterval, base * Double(1 << exponent))
    }

    /// Re-evaluate against elapsed monotonic time when power or network conditions change;
    /// restarting a timer must not postpone a check that is already due.
    public static func delay(for conditions: Conditions, consecutiveFailures: Int = 0,
                             lastRefreshDuration: TimeInterval = 0, elapsed: TimeInterval?) -> TimeInterval? {
        guard let interval = interval(for: conditions, consecutiveFailures: consecutiveFailures,
                                      lastRefreshDuration: lastRefreshDuration) else { return nil }
        guard let elapsed, elapsed.isFinite else { return interval }
        return max(0, interval - max(0, elapsed))
    }
}
