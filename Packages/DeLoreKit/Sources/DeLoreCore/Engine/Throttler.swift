import Foundation

/// Decides how long to wait before the next destructive request.
///
/// Combines a minimum gap with jitter, burst protection, an hourly cap, server-imposed
/// cool-downs and an adaptive multiplier that grows on rate limits and relaxes slowly.
public struct Throttler: Sendable {
    public private(set) var policy: RatePolicy
    public private(set) var slowdown: Double = 1
    public private(set) var blockedUntil: Date?
    public private(set) var consecutiveRateLimits = 0
    public private(set) var rateLimitsThisRun = 0

    /// Timestamps of recent requests, bounded by `hourlyLimit`.
    private var recent: [Date] = []
    private var successesSinceSlowdown = 0

    public init(policy: RatePolicy) {
        self.policy = policy
    }

    public func delayBeforeNextRequest(now: Date, random: RandomSource) -> TimeInterval {
        var delay: TimeInterval = 0

        if let last = recent.last {
            let gap = policy.minimumDelay * slowdown + random.nextUnit() * policy.maximumJitter
            delay = max(delay, last.addingTimeInterval(gap).timeIntervalSince(now))
        }

        if policy.burstLimit > 0 {
            let windowStart = now.addingTimeInterval(-policy.burstWindow)
            let inWindow = recent.filter { $0 > windowStart }
            if inWindow.count >= policy.burstLimit, let oldest = inWindow.first {
                delay = max(delay, oldest.addingTimeInterval(policy.burstWindow).timeIntervalSince(now))
            }
        }

        if policy.hourlyLimit > 0 {
            let hourStart = now.addingTimeInterval(-3600)
            let inHour = recent.filter { $0 > hourStart }
            if inHour.count >= policy.hourlyLimit, let oldest = inHour.first {
                delay = max(delay, oldest.addingTimeInterval(3600).timeIntervalSince(now))
            }
        }

        if let blockedUntil {
            delay = max(delay, blockedUntil.timeIntervalSince(now))
        }

        return max(0, delay)
    }

    public mutating func recordRequest(at date: Date) {
        recent.append(date)
        let hourStart = date.addingTimeInterval(-3600)
        if let firstKept = recent.firstIndex(where: { $0 > hourStart }), firstKept > 0 {
            recent.removeFirst(firstKept)
        }
        let cap = max(policy.hourlyLimit, policy.burstLimit, 1)
        if recent.count > cap { recent.removeFirst(recent.count - cap) }
    }

    public mutating func recordSuccess() {
        consecutiveRateLimits = 0
        guard slowdown > 1 else { return }
        successesSinceSlowdown += 1
        if successesSinceSlowdown >= policy.successesToRelax {
            successesSinceSlowdown = 0
            slowdown = max(1, slowdown / policy.slowdownFactor)
        }
    }

    /// Returns the cool-down applied for this rate limit.
    @discardableResult
    public mutating func recordRateLimit(at now: Date, retryAfter: TimeInterval?, random: RandomSource) -> TimeInterval {
        consecutiveRateLimits += 1
        rateLimitsThisRun += 1
        successesSinceSlowdown = 0
        slowdown = min(policy.maximumSlowdown, slowdown * policy.slowdownFactor)

        let exponent = Double(max(0, consecutiveRateLimits - 1))
        let base = min(policy.rateLimitCooldownMaximum, policy.rateLimitCooldown * pow(2, exponent))
        // Up to +20% jitter so many devices don't come back at the same moment.
        var cooldown = base * (1 + 0.2 * random.nextUnit())
        if let retryAfter, retryAfter > cooldown { cooldown = retryAfter }
        blockedUntil = now.addingTimeInterval(cooldown)
        return cooldown
    }

    public var shouldStopForRateLimits: Bool {
        consecutiveRateLimits >= policy.maxConsecutiveRateLimits || rateLimitsThisRun >= policy.maxRateLimitsPerRun
    }

    /// Called when the user resumes after a rate-limit pause: keep the slow-down, reset counters.
    public mutating func beginNewRun() {
        consecutiveRateLimits = 0
        rateLimitsThisRun = 0
    }
}

public enum Backoff {
    /// Exponential backoff with "full jitter": uniform in `0.5x...1x` of the capped exponential.
    /// The lower bound keeps a meaningful minimum pause even with unlucky randomness.
    public static func delay(forAttempt attempt: Int, policy: RatePolicy, random: RandomSource) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let capped = min(policy.backoffMaximum, policy.backoffBase * pow(policy.backoffFactor, exponent))
        return capped * (0.5 + 0.5 * random.nextUnit())
    }
}
