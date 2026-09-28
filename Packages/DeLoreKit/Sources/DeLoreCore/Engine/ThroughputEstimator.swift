import Foundation

/// Estimates remaining time from the speed actually observed on this device, including
/// pacing waits and cool-downs. Returns nothing until there's enough signal to be honest.
public struct ThroughputEstimator: Sendable {
    public static let minimumSamples = 5
    private let smoothing: Double
    private var lastEvent: Date?
    public private(set) var averageSecondsPerItem: Double?
    public private(set) var samples = 0

    public init(smoothing: Double = 0.15) {
        self.smoothing = smoothing
    }

    /// Starts timing a new run segment; gaps across pauses aren't counted.
    public mutating func beginSegment(at date: Date) {
        lastEvent = date
    }

    public mutating func endSegment() {
        lastEvent = nil
    }

    public mutating func recordItem(at date: Date) {
        defer { lastEvent = date }
        guard let lastEvent else { return }
        let elapsed = max(0, date.timeIntervalSince(lastEvent))
        if let average = averageSecondsPerItem {
            averageSecondsPerItem = average + smoothing * (elapsed - average)
        } else {
            averageSecondsPerItem = elapsed
        }
        samples += 1
    }

    public func estimatedSeconds(remaining: Int) -> TimeInterval? {
        guard remaining > 0 else { return 0 }
        guard samples >= Self.minimumSamples, let averageSecondsPerItem else { return nil }
        return averageSecondsPerItem * Double(remaining)
    }
}
