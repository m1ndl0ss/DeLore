import Foundation

/// Time source for the engine. Injected so tests can run hours of pacing in milliseconds.
public protocol EngineClock: Sendable {
    var now: Date { get }
    /// Suspends for `seconds`. Must throw `CancellationError` when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: EngineClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Source of randomness for jitter. Injected so tests are deterministic.
public protocol RandomSource: Sendable {
    /// Uniform value in `0..<1`.
    func nextUnit() -> Double
}

public struct SystemRandom: RandomSource {
    public init() {}
    public func nextUnit() -> Double { Double.random(in: 0..<1) }
}

/// Deterministic SplitMix64 generator.
public final class SeededRandom: RandomSource, @unchecked Sendable {
    private var state: UInt64
    private let lock = NSLock()

    public init(seed: UInt64) { state = seed }

    public func nextUInt64() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public func nextUnit() -> Double {
        Double(nextUInt64() >> 11) / Double(UInt64(1) << 53)
    }

    public func next(below upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(nextUInt64() % UInt64(upperBound))
    }
}
