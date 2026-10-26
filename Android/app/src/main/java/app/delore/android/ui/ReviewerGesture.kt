package app.delore.android.ui

/**
 * Hidden entry point to the reviewer sample inbox. Deliberately undiscoverable:
 * on the logged-out welcome screen, long-press the Retract wordmark for 3s, then
 * within 5s tap "Connect Instagram" 5 times. No visual/haptic feedback until it
 * unlocks. Pure state machine so the timing window and reset rules are unit-tested.
 *
 * Not thread-safe; drive it from the main thread.
 */
class ReviewerGesture(
    private val longPressMillis: Long = 3_000,
    private val tapWindowMillis: Long = 5_000,
    private val requiredTaps: Int = 5,
) {
    private var armedAt: Long? = null
    private var taps = 0

    val isArmed: Boolean get() = armedAt != null

    /** Call when the wordmark has been held for at least [longPressMillis]. Arms the tap window. */
    fun onLongPressCompleted(nowMillis: Long) {
        armedAt = nowMillis
        taps = 0
    }

    /**
     * Call on each "Connect Instagram" tap. Returns true exactly once, on the
     * tap that completes the sequence. Any tap outside an armed window, or after
     * the window has expired, resets the machine (wrong sequence → start over).
     */
    fun onConnectTap(nowMillis: Long): Boolean {
        val armed = armedAt
        if (armed == null || nowMillis - armed > tapWindowMillis) {
            reset()
            return false
        }
        taps += 1
        if (taps >= requiredTaps) {
            reset()
            return true
        }
        return false
    }

    fun reset() {
        armedAt = null
        taps = 0
    }
}
