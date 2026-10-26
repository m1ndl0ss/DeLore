package app.delore.android

import app.delore.android.ui.ReviewerGesture
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReviewerGestureTest {
    private fun gesture() = ReviewerGesture(longPressMillis = 3_000, tapWindowMillis = 5_000, requiredTaps = 5)

    @Test
    fun fiveTapsWithinWindowAfterLongPressUnlocks() {
        val g = gesture()
        g.onLongPressCompleted(0)
        assertFalse(g.onConnectTap(100))
        assertFalse(g.onConnectTap(200))
        assertFalse(g.onConnectTap(300))
        assertFalse(g.onConnectTap(400))
        assertTrue("fifth tap in window unlocks", g.onConnectTap(500))
    }

    @Test
    fun tapsBeforeLongPressDoNothing() {
        val g = gesture()
        repeat(5) { assertFalse(g.onConnectTap(it * 100L)) }
        assertFalse(g.isArmed)
    }

    @Test
    fun tapAfterWindowExpiresResetsAndFails() {
        val g = gesture()
        g.onLongPressCompleted(0)
        assertFalse(g.onConnectTap(100))
        assertFalse(g.onConnectTap(200))
        // 5001ms after arming: window closed.
        assertFalse(g.onConnectTap(5_001))
        assertFalse(g.isArmed)
        // Even a burst now does nothing without a fresh long-press.
        repeat(5) { assertFalse(g.onConnectTap(5_100 + it * 10L)) }
    }

    @Test
    fun fifthTapExactlyAtWindowEdgeStillUnlocks() {
        val g = gesture()
        g.onLongPressCompleted(1_000)
        repeat(4) { assertFalse(g.onConnectTap(1_000 + it * 10L)) }
        assertTrue(g.onConnectTap(6_000)) // exactly armedAt + 5000
    }

    @Test
    fun relongPressRestartsTapCount() {
        val g = gesture()
        g.onLongPressCompleted(0)
        g.onConnectTap(100)
        g.onConnectTap(200)
        g.onConnectTap(300) // 3 taps so far
        g.onLongPressCompleted(400) // re-arm resets count
        assertFalse(g.onConnectTap(500))
        assertFalse(g.onConnectTap(600))
        assertFalse(g.onConnectTap(700))
        assertFalse(g.onConnectTap(800))
        assertTrue("needs 5 fresh taps after re-arm", g.onConnectTap(900))
    }

    @Test
    fun unlockingOnceDoesNotUnlockAgainWithoutRearm() {
        val g = gesture()
        g.onLongPressCompleted(0)
        repeat(4) { g.onConnectTap(100L + it) }
        assertTrue(g.onConnectTap(500))
        // After unlock the machine is reset; further taps do nothing.
        assertFalse(g.isArmed)
        assertFalse(g.onConnectTap(600))
    }
}
