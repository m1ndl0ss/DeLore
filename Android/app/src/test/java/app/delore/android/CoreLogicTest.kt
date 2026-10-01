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
import app.delore.android.instagram.InstagramHTTPClient
import app.delore.android.instagram.InstagramItemKind
import app.delore.android.instagram.InstagramLoginPolicy
import app.delore.android.instagram.InstagramResponseClassifier
import app.delore.android.instagram.InstagramWebBootstrap
import app.delore.android.instagram.InstagramWebConstants
import app.delore.android.instagram.InstagramWebFormat
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
    fun classifierTreatsGraphQLUnsendAsSuccess() {
        val body = """{"data":{"direct_unsend_message":true}}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = true)
        assertEquals(null, error)
    }

    @Test
    fun classifierDoesNotTreatNonJsonUnsendAsSuccess() {
        val facebook = """for (;;);{"__ar":1,"error":1357004}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), facebook), destructive = true)
        assertTrue(error is IntegrationError.UnexpectedResponse)
        val htmlish = "self.__next_f.push([1,\"not a delete\"])".toByteArray()
        val htmlError = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), htmlish), destructive = true)
        assertTrue(htmlError is IntegrationError.UnexpectedResponse)
    }

    @Test
    fun classifierAcceptsFacebookPrefixedGraphQLUnsend() {
        val body = """for (;;);{"data":{"direct_unsend_message":true}}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = true)
        assertEquals(null, error)
    }

    @Test
    fun unsendUrlUsesInstagramApiHost() {
        val url = InstagramHTTPClient.instagramUrl(
            "/api/v1/direct_v2/threads/1/items/2/delete/",
            emptyMap(),
            InstagramWebConstants.API_HOST,
        )
        assertTrue(url.startsWith("https://i.instagram.com/"))
        assertTrue(url.contains("/items/2/delete/"))
        val www = InstagramHTTPClient.instagramUrl(
            "/api/v1/direct_v2/threads/1/items/2/delete/",
            emptyMap(),
            InstagramWebConstants.WWW_HOST,
        )
        assertTrue(www.startsWith("https://www.instagram.com/"))
        assertTrue(www.contains("/items/2/delete/"))
    }

    @Test
    fun unsendUrlRejectsNonInstagramHosts() {
        try {
            InstagramHTTPClient.instagramUrl("/api/v1/direct_v2/inbox/", emptyMap(), "evil.example")
            org.junit.Assert.fail("expected rejection")
        } catch (_: Exception) {
        }
    }

    @Test
    fun parseThreadKeepsLongNumericItemIds() {
        val body = """{"thread":{"items":[{"item_id":32309391968822496455072488775221248,"user_id":42,"timestamp":1}]}}""".toByteArray()
        val page = InstagramWebFormat.parseThread(body)
        assertEquals("32309391968822496455072488775221248", page.items.single().itemID)
    }

    @Test
    fun parseThreadClassifiesPhotosTextsSharesAndVoice() {
        val body = """
            {"thread":{"items":[
              {"item_id":"1","user_id":"42","timestamp":1,"item_type":"text","text":"hi"},
              {"item_id":"2","user_id":"42","timestamp":1,"media":{"image_versions2":{}}},
              {"item_id":"3","user_id":"42","timestamp":1,"item_type":"text","media":{"video_versions":[]}},
              {"item_id":"4","user_id":"42","timestamp":1,"item_type":"media_share","media":{"image_versions2":{}}},
              {"item_id":"5","user_id":"42","timestamp":1,"voice_media":{}},
              {"item_id":"6","user_id":"42","timestamp":1,"item_type":"generic_xma","xma":{}},
              {"item_id":"7","user_id":"42","timestamp":1,"item_type":"raven_media"},
              {"item_id":"8","user_id":"42","timestamp":1,"item_type":"placeholder"}
            ]}}
        """.trimIndent().toByteArray()
        val kinds = InstagramWebFormat.parseThread(body).items.map { it.kind }
        assertEquals(
            listOf(
                MessageKind.TEXT,
                MessageKind.MEDIA,
                MessageKind.MEDIA,
                MessageKind.LINK,
                MessageKind.VOICE,
                MessageKind.LINK,
                MessageKind.MEDIA,
                MessageKind.OTHER,
            ),
            kinds,
        )
    }

    @Test
    fun itemKindDoesNotDefaultMissingTypeToText() {
        assertEquals(
            MessageKind.MEDIA,
            InstagramItemKind.classify(null, hasVoice = false, hasPhotoVideo = true, hasShareOrLink = false, hasText = true),
        )
        assertEquals(
            MessageKind.LINK,
            InstagramItemKind.classify("text", hasVoice = false, hasPhotoVideo = false, hasShareOrLink = true, hasText = true),
        )
        assertEquals(
            MessageKind.TEXT,
            InstagramItemKind.classify(null, hasVoice = false, hasPhotoVideo = false, hasShareOrLink = false, hasText = true),
        )
    }

    @Test
    fun bootstrapReadsDtsgFromPageHtml() {
        val html = """["DTSGInitialData",[],{"token":"NAcTESTTOKEN"}]"""
        assertEquals("NAcTESTTOKEN", InstagramWebBootstrap.fbDtsg(html))
        val escaped = "\\" + "u0022"
        val unicode = """["DTSGInitialData",[],{${escaped}token${escaped}:${escaped}NAcUNICODE${escaped}}]"""
        assertEquals("NAcUNICODE", InstagramWebBootstrap.fbDtsg(unicode))
        assertEquals("2" + "NAcTESTTOKEN".sumOf { it.code }, InstagramWebBootstrap.jazoest("NAcTESTTOKEN"))
    }

    @Test
    fun classifierTreatsGraphqlLoginContinueAsUnexpectedNotSession() {
        val body = """for (;;);{"__ar":1,"error":1357001,"errorSummary":"Log in to continue"}""".toByteArray()
        val error = InstagramResponseClassifier.classify(HTTPResponse(200, emptyMap(), body), destructive = true)
        assertTrue(error is IntegrationError.UnexpectedResponse)
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
        val focused = InboxReadProgress(chatsTotal = 1, currentTitle = "@maya", sendsFound = 12)
        assertEquals("Reading @maya", focused.headline)
        assertEquals("12 messages found so far", focused.detail)
        val starting = InboxReadProgress(chatsTotal = 1, chatsRead = 0, currentTitle = "@maya", sendsFound = 0)
        assertFalse(starting.isComplete)
        assertFalse(starting.isListing)
        assertEquals("Reading @maya", starting.headline)
        assertEquals("0 messages found so far", starting.detail)
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

private class MemorySecrets : app.delore.android.secrets.SecretStore {
    private val values = mutableMapOf<String, String>()
    override fun string(key: String): String? = values[key]
    override fun data(key: String): ByteArray? = values[key]?.toByteArray(Charsets.UTF_8)
    override fun set(value: String, key: String) { values[key] = value }
    override fun set(value: ByteArray, key: String) { values[key] = String(value, Charsets.UTF_8) }
    override fun remove(key: String) { values.remove(key) }
    override fun wipePreserving(keys: Collection<String>) {
        val keep = keys.mapNotNull { k -> values[k]?.let { k to it } }.toMap()
        values.clear()
        values.putAll(keep)
    }
}

class PromoCodeTest {
    @Test
    fun complimentaryIsCaseInsensitive() {
        assertEquals(app.delore.android.billing.PromoOffer.COMPLIMENTARY, app.delore.android.billing.PromoCatalog.offer("kandal24"))
    }

    @Test
    fun campaignCodesAreTenPercentOff() {
        assertEquals(
            app.delore.android.billing.PromoOffer.PERCENT_OFF,
            app.delore.android.billing.PromoCatalog.offer("REF10", setOf("REF10")),
        )
    }

    @Test
    fun discountedPriceKeepsCurrency() {
        assertEquals("$53.99", app.delore.android.billing.PromoCatalog.discountedPrice("$59.99", 10))
    }

    @Test
    fun threeFailedGuessesLockTheDay() {
        val vault = app.delore.android.billing.PromoVault(MemorySecrets())
        val now = 1_775_000_000_000L
        assertTrue(vault.redeem("WRONG1", now) is app.delore.android.billing.PromoRedeemResult.Invalid)
        vault.redeem("WRONG2", now)
        vault.redeem("WRONG3", now)
        assertEquals(app.delore.android.billing.PromoRedeemResult.Locked, vault.redeem("KANDAL24", now))
    }

    @Test
    fun emptyGuessDoesNotCount() {
        val vault = app.delore.android.billing.PromoVault(MemorySecrets())
        assertEquals(app.delore.android.billing.PromoRedeemResult.Empty, vault.redeem("  "))
        assertEquals(3, vault.remainingGuesses())
    }

    @Test
    fun complimentaryPersists() {
        val store = MemorySecrets()
        val vault = app.delore.android.billing.PromoVault(store)
        assertTrue(vault.redeem("KANDAL24") is app.delore.android.billing.PromoRedeemResult.Applied)
        assertTrue(app.delore.android.billing.PromoVault(store).isComplimentary)
    }

    @Test
    fun guessesResetNextDay() {
        val vault = app.delore.android.billing.PromoVault(MemorySecrets())
        val day1 = 1_775_000_000_000L
        val day2 = day1 + 86_400_000L
        vault.redeem("A", day1)
        vault.redeem("B", day1)
        vault.redeem("C", day1)
        val result = vault.redeem("KANDAL24", day2)
        assertTrue(result is app.delore.android.billing.PromoRedeemResult.Applied)
    }
}
