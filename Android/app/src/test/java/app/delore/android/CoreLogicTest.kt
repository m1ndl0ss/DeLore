package app.delore.android

import app.delore.android.domain.CleanupAllowance
import app.delore.android.domain.CleanupAllowanceDecision
import app.delore.android.domain.CleanupFilter
import app.delore.android.domain.CleanupRequest
import app.delore.android.domain.CleanupScope
import app.delore.android.domain.ConversationID
import app.delore.android.domain.ConversationSummary
import app.delore.android.domain.DiscoveredMessage
import app.delore.android.domain.EntitlementState
import app.delore.android.domain.HTTPResponse
import app.delore.android.domain.InboxReadProgress
import app.delore.android.domain.IntegrationError
import app.delore.android.domain.LibraryOverview
import app.delore.android.domain.MessageKind
import app.delore.android.domain.MessageRef
import app.delore.android.domain.ParticipantID
import app.delore.android.engine.QueueBuilder
import app.delore.android.engine.RatePolicy
import app.delore.android.instagram.InstagramLoginPolicy
import app.delore.android.instagram.InstagramResponseClassifier
import app.delore.android.instagram.InstagramWebSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RatePolicyTest {
    @Test
    fun estimatedDurationHonoursHourlyCap() {
        val seconds = RatePolicy.conservative.estimatedDuration(300)
        assertEquals(3600.0, seconds!!, 0.01)
    }

    @Test
    fun emptyJobIsInstant() {
        assertEquals(0.0, RatePolicy.conservative.estimatedDuration(0)!!, 0.0)
    }
}

class EntitlementTest {
    @Test
    fun freeTierLimitedAt100() {
        val decision = CleanupAllowance.evaluate(
            requestedCount = 200,
            usesAdvancedFilters = false,
            entitlement = EntitlementState(),
            freeLimit = 100,
        )
        assertEquals(CleanupAllowanceDecision.Limited(100), decision)
    }

    @Test
    fun filtersNeedPro() {
        val decision = CleanupAllowance.evaluate(
            requestedCount = 5,
            usesAdvancedFilters = true,
            entitlement = EntitlementState(),
            freeLimit = 100,
        )
        assertEquals(CleanupAllowanceDecision.FiltersRequirePro, decision)
    }

    @Test
    fun proIsUnlimited() {
        val decision = CleanupAllowance.evaluate(
            requestedCount = 10_000,
            usesAdvancedFilters = true,
            entitlement = EntitlementState(isPro = true),
            freeLimit = 100,
        )
        assertTrue(decision is CleanupAllowanceDecision.Allowed)
        assertFalse((decision as CleanupAllowanceDecision.Allowed).consumesPass)
    }
}

class FilterAndQueueTest {
    @Test
    fun beforeOrAfterIsOrNotAnd() {
        val after = CleanupFilter(sentAfter = 1_000)
        val before = CleanupFilter(sentBefore = 1_000)
        val message = DiscoveredMessage(
            ref = MessageRef(ConversationID("c"), "m"),
            authorID = ParticipantID("ig:1"),
            sentAtMillis = 2_000,
            kind = MessageKind.TEXT,
        )
        assertTrue(after.matches(message))
        assertFalse(before.matches(message))
    }

    @Test
    fun estimatedCountUsesSummaries() {
        val conversations = listOf(
            ConversationSummary(
                id = ConversationID("a"),
                title = "A",
                sentByOwner = 10,
                receivedFromOthers = 3,
            ),
        )
        val count = QueueBuilder.estimatedCount(
            CleanupRequest(CleanupScope.Everything),
            conversations,
        )
        assertEquals(10, count)
    }
}

class InstagramPolicyTest {
    @Test
    fun loginHostsAreAllowlisted() {
        assertTrue(InstagramLoginPolicy.allowsNavigation("https://www.instagram.com/accounts/login/"))
        assertTrue(InstagramLoginPolicy.allowsNavigation("https://www.facebook.com/login.php"))
        assertFalse(InstagramLoginPolicy.allowsNavigation("https://evil.example/login"))
        assertFalse(InstagramLoginPolicy.allowsNavigation("http://www.instagram.com/"))
    }

    @Test
    fun sessionNeedsInstagramCookies() {
        val session = InstagramWebSession.from(
            listOf(
                InstagramWebSession.Cookie("sessionid", "abc", ".instagram.com", "/", true),
                InstagramWebSession.Cookie("ds_user_id", "42", ".instagram.com", "/", true),
                InstagramWebSession.Cookie("csrftoken", "tok", ".instagram.com", "/", true),
                InstagramWebSession.Cookie("c_user", "fb", ".facebook.com", "/", true),
            ),
        )
        assertEquals("42", session!!.userID)
        assertTrue(session.hasLiveSession)
        assertFalse(session.cookies.any { it.domain.contains("facebook") })
    }

    @Test
    fun classifierStopsOnCheckpoint() {
        val body = """{"message":"checkpoint_required","status":"fail"}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = true)
        assertEquals(IntegrationError.VerificationRequired, error)
    }

    @Test
    fun classifierStopsOnLoginRequired() {
        val body = """{"message":"login_required"}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = false)
        assertEquals(IntegrationError.SessionExpired, error)
    }

    @Test
    fun classifierDoesNotTreatInboxMessagesAsRateLimit() {
        val body = """{"status":"ok","inbox":{"threads":[{"thread_id":"1","items":[{"item_id":"m","text":"this is spam and too many please wait a few minutes"}]}]}}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = false)
        assertEquals(null, error)
    }

    @Test
    fun classifierStillMapsTopLevelFeedbackRequired() {
        val body = """{"feedback_required":true,"spam":true,"status":"fail"}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = false)
        assertTrue(error is IntegrationError.RateLimited)
    }

    @Test
    fun inboxReadProgressMovesFromListingToReading() {
        val listing = InboxReadProgress(chatsFound = 24)
        assertTrue(listing.isListing)
        assertTrue(listing.fraction in 0.05..0.16)
        val reading = InboxReadProgress(chatsFound = 40, chatsRead = 10, chatsTotal = 40, sendsFound = 18, currentTitle = "Alex")
        assertFalse(reading.isListing)
        assertEquals("Alex", reading.displayChat)
        assertTrue(reading.fraction > listing.fraction)
        assertTrue(reading.fraction < 1.0)
        val done = InboxReadProgress(chatsFound = 40, chatsRead = 40, chatsTotal = 40, sendsFound = 90)
        assertTrue(done.isComplete)
        assertEquals(1.0, done.fraction, 0.0001)
    }

    @Test
    fun unreadListingsAreNotCleanable() {
        val stub = ConversationSummary(
            id = ConversationID("t1"),
            title = "@maya",
            sentByOwner = 0,
            receivedFromOthers = 0,
            messagesLoaded = false,
        )
        assertFalse(stub.isCleanable)
        val overview = LibraryOverview(listOf(stub))
        assertEquals(0, overview.sentByOwner)
        assertEquals(1, overview.unreadConversations.size)
        assertTrue(overview.cleanableConversations.isEmpty())
    }
}
