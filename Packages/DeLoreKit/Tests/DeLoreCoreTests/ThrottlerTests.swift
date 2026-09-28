@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

final class ThrottlerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testFirstRequestHasNoDelay() {
        let throttler = Throttler(policy: .conservative)
        XCTAssertEqual(throttler.delayBeforeNextRequest(now: start, random: SeededRandom(seed: 1)), 0)
    }

    func testMinimumDelayWithJitter() {
        var throttler = Throttler(policy: .conservative)
        throttler.recordRequest(at: start)
        let random = SeededRandom(seed: 3)
        for _ in 0..<100 {
            let delay = throttler.delayBeforeNextRequest(now: start, random: random)
            XCTAssertGreaterThanOrEqual(delay, RatePolicy.conservative.minimumDelay)
            XCTAssertLessThanOrEqual(delay, RatePolicy.conservative.minimumDelay + RatePolicy.conservative.maximumJitter)
        }
    }

    func testBurstProtection() {
        var policy = RatePolicy.conservative
        policy.minimumDelay = 0
        policy.maximumJitter = 0
        policy.burstLimit = 3
        policy.burstWindow = 60
        var throttler = Throttler(policy: policy)
        for second in 0..<3 { throttler.recordRequest(at: start.addingTimeInterval(Double(second))) }
        let delay = throttler.delayBeforeNextRequest(now: start.addingTimeInterval(3), random: SeededRandom(seed: 1))
        XCTAssertEqual(delay, 57, accuracy: 0.001)
    }

    func testHourlyCap() {
        var policy = RatePolicy.conservative
        policy.minimumDelay = 0
        policy.maximumJitter = 0
        policy.burstLimit = 0
        policy.hourlyLimit = 5
        var throttler = Throttler(policy: policy)
        for minute in 0..<5 { throttler.recordRequest(at: start.addingTimeInterval(Double(minute) * 60)) }
        let delay = throttler.delayBeforeNextRequest(now: start.addingTimeInterval(300), random: SeededRandom(seed: 1))
        XCTAssertEqual(delay, 3_300, accuracy: 0.001)
    }

    func testRateLimitCooldownGrowsAndIsCapped() {
        var throttler = Throttler(policy: .conservative)
        let random = SeededRandom(seed: 5)
        var previous: TimeInterval = 0
        for _ in 0..<6 {
            let cooldown = throttler.recordRateLimit(at: start, retryAfter: nil, random: random)
            XCTAssertGreaterThanOrEqual(cooldown, min(previous, RatePolicy.conservative.rateLimitCooldownMaximum))
            XCTAssertLessThanOrEqual(cooldown, RatePolicy.conservative.rateLimitCooldownMaximum * 1.2)
            previous = cooldown
        }
        XCTAssertTrue(throttler.shouldStopForRateLimits)
        XCTAssertEqual(throttler.slowdown, RatePolicy.conservative.maximumSlowdown)
    }

    func testSlowdownRelaxesAfterSustainedSuccess() {
        var throttler = Throttler(policy: .conservative)
        throttler.recordRateLimit(at: start, retryAfter: nil, random: SeededRandom(seed: 1))
        XCTAssertEqual(throttler.slowdown, 2)
        for _ in 0..<RatePolicy.conservative.successesToRelax { throttler.recordSuccess() }
        XCTAssertEqual(throttler.slowdown, 1)
        XCTAssertEqual(throttler.consecutiveRateLimits, 0)
    }

    func testBackoffIsExponentialBoundedAndJittered() {
        let policy = RatePolicy.conservative
        let random = SeededRandom(seed: 11)
        for attempt in 1...20 {
            let delay = Backoff.delay(forAttempt: attempt, policy: policy, random: random)
            let cap = min(policy.backoffMaximum, policy.backoffBase * pow(policy.backoffFactor, Double(attempt - 1)))
            XCTAssertGreaterThanOrEqual(delay, cap * 0.5)
            XCTAssertLessThanOrEqual(delay, cap)
        }
    }

    func testEstimatorNeedsSamplesBeforeClaimingAnything() {
        var estimator = ThroughputEstimator()
        estimator.beginSegment(at: start)
        XCTAssertNil(estimator.estimatedSeconds(remaining: 100))
        for index in 1...ThroughputEstimator.minimumSamples {
            estimator.recordItem(at: start.addingTimeInterval(Double(index) * 10))
        }
        XCTAssertEqual(try XCTUnwrap(estimator.estimatedSeconds(remaining: 100)), 1_000, accuracy: 0.001)
        XCTAssertEqual(estimator.estimatedSeconds(remaining: 0), 0)
    }

    func testEstimatorIgnoresTimeSpentPaused() {
        var estimator = ThroughputEstimator(smoothing: 1)
        estimator.beginSegment(at: start)
        estimator.recordItem(at: start.addingTimeInterval(5))
        estimator.endSegment()
        estimator.beginSegment(at: start.addingTimeInterval(10_000))
        estimator.recordItem(at: start.addingTimeInterval(10_005))
        XCTAssertEqual(estimator.averageSecondsPerItem ?? 0, 5, accuracy: 0.001)
    }
}
