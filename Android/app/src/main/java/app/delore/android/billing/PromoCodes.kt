package app.delore.android.billing

import app.delore.android.secrets.SecretStore
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

enum class PromoOffer {
    COMPLIMENTARY,
    PERCENT_OFF,
}

sealed class PromoRedeemResult {
    data object Empty : PromoRedeemResult()
    data object Locked : PromoRedeemResult()
    data class Invalid(val remaining: Int) : PromoRedeemResult()
    data class Applied(val offer: PromoOffer) : PromoRedeemResult()
}

/**
 * Campaign (percent-off) codes and complimentary Instagram usernames refresh from a hosted
 * JSON file. Complimentary is username-allowlist only — not a redeemable binary code.
 */
object PromoCatalog {
    val bakedPercentOffCodes: Set<String> = setOf("RETRACT10", "REF10")
    const val CAMPAIGN_PERCENT_OFF = 10

    val percentOffCodes: Set<String> get() = bakedPercentOffCodes

    fun normalize(raw: String): String = raw.trim().uppercase(Locale.US)

    /** Instagram usernames are compared case-insensitively without a leading `@`. */
    fun normalizeUsername(raw: String): String =
        raw.trim().trimStart('@').lowercase(Locale.US)

    fun offer(
        raw: String,
        percentOffCodes: Set<String> = bakedPercentOffCodes,
        percentOff: Int = CAMPAIGN_PERCENT_OFF,
    ): PromoOffer? {
        val code = normalize(raw)
        if (code.isEmpty()) return null
        // Legacy binary gift code — permanently retired. Complimentary is username allowlist only.
        if (code == "KANDAL24") return null
        if (code in percentOffCodes) return PromoOffer.PERCENT_OFF
        return null
    }

    fun isValidUsername(username: String): Boolean =
        username.length in 1..30 && username.all { it.isLetterOrDigit() || it == '.' || it == '_' }

    fun discountedPrice(display: String, percentOff: Int): String {
        if (percentOff <= 0 || percentOff >= 100) return display
        val match = Regex("""\d+[.,]\d{1,2}|\d+""").find(display) ?: return display
        val token = match.value
        val usesComma = token.contains(',')
        val value = token.replace(',', '.').toDoubleOrNull() ?: return display
        val discounted = ((value * (100 - percentOff) / 100.0) * 100.0).roundToInt() / 100.0
        val formatted = String.format(Locale.US, "%.2f", discounted)
            .let { if (usesComma) it.replace('.', ',') else it }
        return display.replaceRange(match.range, formatted)
    }
}

/** Mutable campaign directory with local cache. */
class PromoCampaignBook(private val store: SecretStore? = null) {
    companion object {
        const val REMOTE_CODES_KEY = "promo.remote.codes"
        const val REMOTE_PERCENT_KEY = "promo.remote.percent"
        const val REMOTE_COMPLIMENTARY_KEY = "promo.remote.complimentaryUsernames"

        fun isValidCode(code: String): Boolean =
            code.length in 3..32 && code.all { it.isLetterOrDigit() }
    }

    private val state = AtomicReference(loadInitial())

    val percentOffCodes: Set<String> get() = state.get().codes
    val percentOff: Int get() = state.get().percent
    val complimentaryHandles: Set<String> get() = state.get().usernames

    fun offer(raw: String): PromoOffer? {
        val snap = state.get()
        return PromoCatalog.offer(raw, snap.codes, snap.percent)
    }

    fun isComplimentaryUsername(raw: String?): Boolean {
        val username = PromoCatalog.normalizeUsername(raw ?: return false)
        if (!PromoCatalog.isValidUsername(username)) return false
        return username in state.get().usernames
    }

    fun replaceCampaign(
        codes: Set<String>,
        percentOff: Int,
        complimentaryUsernames: Set<String> = emptySet(),
    ): Boolean {
        val cleaned = codes.map(PromoCatalog::normalize)
            .filter(::isValidCode)
            .toSet()
        val percent = percentOff.coerceIn(1, 99)
        val handles = complimentaryUsernames.map(PromoCatalog::normalizeUsername)
            .filter(PromoCatalog::isValidUsername)
            .toSet()
        if (cleaned.isEmpty()) return false
        state.set(Snap(cleaned, percent, handles))
        store?.set(cleaned.sorted().joinToString(","), REMOTE_CODES_KEY)
        store?.set(percent.toString(), REMOTE_PERCENT_KEY)
        store?.set(handles.sorted().joinToString(","), REMOTE_COMPLIMENTARY_KEY)
        return true
    }

    private fun loadInitial(): Snap {
        val raw = store?.string(REMOTE_CODES_KEY)?.takeIf { it.isNotBlank() } ?: return Snap(
            PromoCatalog.bakedPercentOffCodes,
            PromoCatalog.CAMPAIGN_PERCENT_OFF,
            emptySet(),
        )
        val codes = raw.split(',')
            .map(PromoCatalog::normalize)
            .filter(::isValidCode)
            .toSet()
        if (codes.isEmpty()) {
            return Snap(PromoCatalog.bakedPercentOffCodes, PromoCatalog.CAMPAIGN_PERCENT_OFF, emptySet())
        }
        val percent = (store?.string(REMOTE_PERCENT_KEY)?.toIntOrNull() ?: PromoCatalog.CAMPAIGN_PERCENT_OFF)
            .coerceIn(1, 99)
        val handles = store?.string(REMOTE_COMPLIMENTARY_KEY).orEmpty()
            .split(',')
            .map(PromoCatalog::normalizeUsername)
            .filter(PromoCatalog::isValidUsername)
            .toSet()
        return Snap(codes, percent, handles)
    }

    private data class Snap(val codes: Set<String>, val percent: Int, val usernames: Set<String>)
}

/** Hosted campaign JSON: `{"percentOff":10,"codes":["RETRACT10"],"complimentaryUsernames":["alice"]}` */
object RemotePromoCatalog {
    const val DEFAULT_URL = "https://kandalintsev.com/r/7f3a/pc.json"

    fun parse(body: String): Triple<Set<String>, Int, Set<String>>? {
        return runCatching {
            val json = JSONObject(body)
            val percent = json.optInt("percentOff", PromoCatalog.CAMPAIGN_PERCENT_OFF)
            val array = json.optJSONArray("codes") ?: return null
            val codes = buildSet {
                for (i in 0 until array.length()) {
                    val code = PromoCatalog.normalize(array.optString(i))
                    if (PromoCampaignBook.isValidCode(code)) add(code)
                }
            }
            val handles = buildSet {
                val users = json.optJSONArray("complimentaryUsernames") ?: return@buildSet
                for (i in 0 until users.length()) {
                    val name = PromoCatalog.normalizeUsername(users.optString(i))
                    if (PromoCatalog.isValidUsername(name)) add(name)
                }
            }
            if (codes.isEmpty() || percent !in 1..99) null else Triple(codes, percent, handles)
        }.getOrNull()
    }

    fun refresh(into: PromoCampaignBook, url: String = DEFAULT_URL): Boolean {
        return runCatching {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 12_000
                readTimeout = 12_000
                requestMethod = "GET"
                setRequestProperty("Accept", "application/json")
                useCaches = false
            }
            try {
                if (connection.responseCode !in 200..299) return false
                val body = connection.inputStream.bufferedReader().use { it.readText() }
                val parsed = parse(body) ?: return false
                into.replaceCampaign(parsed.first, parsed.second, parsed.third)
            } finally {
                connection.disconnect()
            }
        }.getOrDefault(false)
    }
}

class PromoVault(
    private val store: SecretStore,
    book: PromoCampaignBook? = null,
    private val resolve: ((String) -> PromoOffer?)? = null,
) {
    companion object {
        const val DAILY_LIMIT = 3
        const val COMPLIMENTARY_KEY = "promo.complimentary"
        const val COMPLIMENTARY_USER_KEY = "promo.complimentaryUser"
        const val COMPLIMENTARY_BOUND_KEY = "promo.complimentaryBound"
        const val PERCENT_KEY = "promo.percentOff"
        const val CODE_KEY = "promo.appliedCode"
        const val GUESS_DAY_KEY = "promo.guess.day"
        const val GUESS_COUNT_KEY = "promo.guess.count"
        /** Nothing complimentary is device-sticky — allowlist is live from the hosted file. */
        val preservedKeys: List<String> = emptyList()
    }

    val campaignBook: PromoCampaignBook = book ?: PromoCampaignBook(store)
    private val resolveOffer: (String) -> PromoOffer? = resolve ?: { campaignBook.offer(it) }

    fun isComplimentaryUsername(username: String?): Boolean = campaignBook.isComplimentaryUsername(username)

    val percentOff: Int get() = store.string(PERCENT_KEY)?.toIntOrNull() ?: 0
    val appliedCode: String? get() = store.string(CODE_KEY)?.trim()?.takeIf { it.isNotEmpty() }

    fun clearLocalUnlocks() {
        clearLegacyComplimentaryFlags()
        store.remove(PERCENT_KEY)
        store.remove(CODE_KEY)
    }

    /** Removes retired binary-gift vault keys. Safe to call on every refresh. */
    fun clearLegacyComplimentaryFlags() {
        store.remove(COMPLIMENTARY_KEY)
        store.remove(COMPLIMENTARY_USER_KEY)
        store.remove(COMPLIMENTARY_BOUND_KEY)
        if (store.string(CODE_KEY)?.equals("KANDAL24", ignoreCase = true) == true) {
            store.remove(CODE_KEY)
        }
    }

    fun remainingGuesses(nowMillis: Long = System.currentTimeMillis()): Int =
        maxOf(0, DAILY_LIMIT - guessCount(nowMillis))

    fun isLocked(nowMillis: Long = System.currentTimeMillis()): Boolean = remainingGuesses(nowMillis) == 0

    fun redeem(
        raw: String,
        nowMillis: Long = System.currentTimeMillis(),
        accountUserId: String? = null,
    ): PromoRedeemResult {
        val code = PromoCatalog.normalize(raw)
        if (code.isEmpty()) return PromoRedeemResult.Empty
        if (isLocked(nowMillis)) return PromoRedeemResult.Locked
        val offer = resolveOffer(code)
        if (offer == null) {
            recordFailedGuess(nowMillis)
            return PromoRedeemResult.Invalid(remainingGuesses(nowMillis))
        }
        apply(offer, code)
        return PromoRedeemResult.Applied(offer)
    }

    private fun apply(offer: PromoOffer, code: String) {
        store.set(code, CODE_KEY)
        when (offer) {
            PromoOffer.COMPLIMENTARY -> Unit // Allowlist-only; ignore legacy redeem.
            PromoOffer.PERCENT_OFF -> store.set(campaignBook.percentOff.toString(), PERCENT_KEY)
        }
    }

    private fun guessCount(nowMillis: Long): Int {
        val day = dayString(nowMillis)
        if (store.string(GUESS_DAY_KEY) != day) return 0
        return store.string(GUESS_COUNT_KEY)?.toIntOrNull() ?: 0
    }

    private fun recordFailedGuess(nowMillis: Long) {
        val day = dayString(nowMillis)
        val next = guessCount(nowMillis) + 1
        store.set(day, GUESS_DAY_KEY)
        store.set(next.toString(), GUESS_COUNT_KEY)
    }

    private fun dayString(nowMillis: Long): String {
        val cal = Calendar.getInstance().apply { timeInMillis = nowMillis }
        return String.format(
            Locale.US,
            "%04d-%02d-%02d",
            cal.get(Calendar.YEAR),
            cal.get(Calendar.MONTH) + 1,
            cal.get(Calendar.DAY_OF_MONTH),
        )
    }
}
