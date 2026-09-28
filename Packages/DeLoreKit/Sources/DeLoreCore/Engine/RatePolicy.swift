import Foundation

/// Tunable pacing and safety limits for destructive requests.
///
/// The engine reads every limit from here so the policy can be tuned (or served from
/// configuration) without touching engine code. Defaults are intentionally conservative.
public struct RatePolicy: Hashable, Codable, Sendable {
    /// Minimum gap between two destructive requests, before adaptive slow-down.
    public var minimumDelay: TimeInterval
    /// Random extra delay in `0...maximumJitter` added to every gap.
    public var maximumJitter: TimeInterval
    /// At most `burstLimit` requests inside any `burstWindow`.
    public var burstLimit: Int
    public var burstWindow: TimeInterval
    /// Hard cap on requests in any rolling hour.
    public var hourlyLimit: Int

    /// Backoff after transient errors: `base * factor^(attempt-1)`, capped, with full jitter.
    public var backoffBase: TimeInterval
    public var backoffFactor: Double
    public var backoffMaximum: TimeInterval

    /// Cool-down after a rate-limit response; doubles for each consecutive rate limit.
    public var rateLimitCooldown: TimeInterval
    public var rateLimitCooldownMaximum: TimeInterval
    /// Pause the job after this many rate limits in a row.
    public var maxConsecutiveRateLimits: Int
    /// Pause the job after this many rate limits in a single run, even if not consecutive.
    public var maxRateLimitsPerRun: Int

    /// Adaptive slow-down applied to `minimumDelay` after rate limits.
    public var slowdownFactor: Double
    public var maximumSlowdown: Double
    /// Successful requests needed before the slow-down relaxes one step.
    public var successesToRelax: Int

    /// Attempts per item (unsend attempts, not reconciliation checks) before it's marked failed.
    public var maxAttemptsPerItem: Int
    /// Pause the job after this many consecutive failed requests of any kind.
    public var maxConsecutiveFailures: Int

    public init(
        minimumDelay: TimeInterval,
        maximumJitter: TimeInterval,
        burstLimit: Int,
        burstWindow: TimeInterval,
        hourlyLimit: Int,
        backoffBase: TimeInterval,
        backoffFactor: Double,
        backoffMaximum: TimeInterval,
        rateLimitCooldown: TimeInterval,
        rateLimitCooldownMaximum: TimeInterval,
        maxConsecutiveRateLimits: Int,
        maxRateLimitsPerRun: Int,
        slowdownFactor: Double,
        maximumSlowdown: Double,
        successesToRelax: Int,
        maxAttemptsPerItem: Int,
        maxConsecutiveFailures: Int
    ) {
        self.minimumDelay = minimumDelay
        self.maximumJitter = maximumJitter
        self.burstLimit = burstLimit
        self.burstWindow = burstWindow
        self.hourlyLimit = hourlyLimit
        self.backoffBase = backoffBase
        self.backoffFactor = backoffFactor
        self.backoffMaximum = backoffMaximum
        self.rateLimitCooldown = rateLimitCooldown
        self.rateLimitCooldownMaximum = rateLimitCooldownMaximum
        self.maxConsecutiveRateLimits = maxConsecutiveRateLimits
        self.maxRateLimitsPerRun = maxRateLimitsPerRun
        self.slowdownFactor = slowdownFactor
        self.maximumSlowdown = maximumSlowdown
        self.successesToRelax = successesToRelax
        self.maxAttemptsPerItem = maxAttemptsPerItem
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    /// Production default: slow and steady.
    public static let conservative = RatePolicy(
        minimumDelay: 4,
        maximumJitter: 2,
        burstLimit: 10,
        burstWindow: 60,
        hourlyLimit: 300,
        backoffBase: 15,
        backoffFactor: 2,
        backoffMaximum: 15 * 60,
        rateLimitCooldown: 10 * 60,
        rateLimitCooldownMaximum: 60 * 60,
        maxConsecutiveRateLimits: 3,
        maxRateLimitsPerRun: 6,
        slowdownFactor: 2,
        maximumSlowdown: 8,
        successesToRelax: 50,
        maxAttemptsPerItem: 3,
        maxConsecutiveFailures: 5
    )

    /// Fast pacing for tests, where nothing talks to Instagram.
    public static let demo = RatePolicy(
        minimumDelay: 0.05,
        maximumJitter: 0.05,
        burstLimit: 1_000,
        burstWindow: 60,
        hourlyLimit: 100_000,
        backoffBase: 0.5,
        backoffFactor: 2,
        backoffMaximum: 4,
        rateLimitCooldown: 2,
        rateLimitCooldownMaximum: 8,
        maxConsecutiveRateLimits: 3,
        maxRateLimitsPerRun: 6,
        slowdownFactor: 2,
        maximumSlowdown: 4,
        successesToRelax: 20,
        maxAttemptsPerItem: 3,
        maxConsecutiveFailures: 5
    )

    /// Honest wall-clock estimate from pacing plus the hourly cap. Jitter is averaged.
    public func estimatedDuration(forItemCount count: Int) -> TimeInterval? {
        guard count > 0 else { return 0 }
        let typicalGap = minimumDelay + maximumJitter / 2
        let fromGaps = Double(count) * typicalGap
        guard hourlyLimit > 0 else { return fromGaps }
        let fromHourlyCap = Double(count) / Double(hourlyLimit) * 3_600
        return max(fromGaps, fromHourlyCap)
    }
}
