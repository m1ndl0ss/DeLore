import Foundation

/// Hidden entry point to the reviewer sample inbox. Deliberately undiscoverable:
/// on the logged-out welcome screen, long-press the Retract wordmark for 3s, then
/// within 5s tap "Connect Instagram" 5 times. No visual/haptic feedback until it
/// unlocks. Pure state machine so the timing window and reset rules are unit-tested.
///
/// Times are seconds from a monotonic clock supplied by the caller.
final class ReviewerGesture {
    private let longPressSeconds: Double
    private let tapWindowSeconds: Double
    private let requiredTaps: Int

    private var armedAt: Double?
    private var taps = 0

    init(longPressSeconds: Double = 3, tapWindowSeconds: Double = 5, requiredTaps: Int = 5) {
        self.longPressSeconds = longPressSeconds
        self.tapWindowSeconds = tapWindowSeconds
        self.requiredTaps = requiredTaps
    }

    var isArmed: Bool { armedAt != nil }

    /// Call when the wordmark has been held for at least `longPressSeconds`. Arms the tap window.
    func onLongPressCompleted(now: Double) {
        armedAt = now
        taps = 0
    }

    /// Call on each "Connect Instagram" tap. Returns true exactly once, on the tap
    /// that completes the sequence. Any tap outside an armed window, or after the
    /// window has expired, resets the machine (wrong sequence → start over).
    func onConnectTap(now: Double) -> Bool {
        guard let armed = armedAt, now - armed <= tapWindowSeconds else {
            reset()
            return false
        }
        taps += 1
        if taps >= requiredTaps {
            reset()
            return true
        }
        return false
    }

    func reset() {
        armedAt = nil
        taps = 0
    }
}
