import DeLoreCore
import Foundation

/// Virtual clock: `sleep` advances time instantly, so hours of pacing run in milliseconds.
public final class ManualClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var slept: [TimeInterval] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public var now: Date { lock.withLock { current } }

    public func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock {
            if seconds > 0 { current = current.addingTimeInterval(seconds) }
            slept.append(seconds)
        }
        await Task.yield()
        try Task.checkCancellation()
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    public var sleeps: [TimeInterval] { lock.withLock { slept } }
    public var totalSlept: TimeInterval { lock.withLock { slept.reduce(0, +) } }
}
