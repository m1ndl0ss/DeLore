package app.delore.android

import app.delore.android.domain.HTTPResponse
import app.delore.android.domain.IntegrationError
import app.delore.android.instagram.InstagramResponseClassifier
import app.delore.android.instagram.InstagramWebFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Empty inbox and expired-session edge cases. Both used to land on the
 * "we'll hold off for a bit" screen, which told the user to wait for something
 * that waiting cannot fix.
 */
class InboxEdgeCasesTest {

    @Test
    fun emptyInboxJsonParsesAsZeroThreads() {
        val body = """{"inbox":{"threads":[],"has_older":false},"status":"ok"}""".toByteArray()
        val page = InstagramWebFormat.parseInbox(body)
        assertTrue(page.threads.isEmpty())
        assertFalse(page.hasOlder)
        assertNull(page.oldestCursor)
    }

    @Test
    fun inboxlessOkResponseIsAnEmptyInboxNotAFailure() {
        val body = """{"status":"ok","viewer":{"username":"apptesting070124"}}""".toByteArray()
        val page = InstagramWebFormat.parseInbox(body)
        assertTrue(page.threads.isEmpty())
        assertFalse(page.hasOlder)
        assertEquals("apptesting070124", page.viewerUsername)
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonOkResponseWithoutInboxStillFails() {
        InstagramWebFormat.parseInbox("""{"status":"fail","message":"transient error"}""".toByteArray())
    }

    @Test
    fun emptyInboxIsNotClassifiedAsAnError() {
        val body = """{"inbox":{"threads":[],"has_older":false},"status":"ok"}""".toByteArray()
        assertNull(InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = false))
    }

    @Test
    fun expiredSessionAsksForLoginInsteadOfHoldingOff() {
        val pause = SyncPause.from(IntegrationError.SessionExpired)
        assertEquals(SyncPauseKind.RECONNECT, pause.kind)
        assertEquals("Session expired, please log in again", pause.title)
        assertNull(pause.retryAfterSeconds)
    }

    /** A logged-out shell must not read as "slow down and retry later". */
    @Test
    fun loggedOutShellMapsToSessionExpired() {
        val html = """<!DOCTYPE html><html><head></head><body>
            <a href="/accounts/login/?next=/direct/inbox/">Log in</a></body></html>"""
        val error = InstagramResponseClassifier.classify(
            HTTPResponse(404, emptyMap(), html.toByteArray()),
            destructive = false,
        )
        assertEquals(IntegrationError.SessionExpired, error)
        assertEquals(SyncPauseKind.RECONNECT, SyncPause.from(error as Exception).kind)
    }
}
