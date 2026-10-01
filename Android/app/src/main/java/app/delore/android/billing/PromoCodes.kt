package app.delore.android.billing

import app.delore.android.secrets.SecretStore
import java.util.Calendar
import java.util.Locale
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

object PromoCatalog {
    const val COMPLIMENTARY_CODE = "KANDAL24"
    const val CAMPAIGN_PERCENT_OFF = 10

    /** Referral codes Matvey issues. Every entry is 10% off at checkout. */
    val percentOffCodes: Set<String> = setOf("RETRACT10", "REF10")

    fun normalize(raw: String): String = raw.trim().uppercase(Locale.US)

    fun offer(raw: String, percentOffCodes: Set<String> = PromoCatalog.percentOffCodes): PromoOffer? {
        val code = normalize(raw)
        if (code.isEmpty()) return null
        if (code == COMPLIMENTARY_CODE) return PromoOffer.COMPLIMENTARY
        if (code in percentOffCodes) return PromoOffer.PERCENT_OFF
        return null
    }

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

class PromoVault(
    private val store: SecretStore,
    private val resolve: (String) -> PromoOffer? = { PromoCatalog.offer(it) },
) {
    companion object {
        const val DAILY_LIMIT = 3
        const val COMPLIMENTARY_KEY = "promo.complimentary"
        const val PERCENT_KEY = "promo.percentOff"
        const val CODE_KEY = "promo.appliedCode"
        const val GUESS_DAY_KEY = "promo.guess.day"
        const val GUESS_COUNT_KEY = "promo.guess.count"
    }

    val isComplimentary: Boolean get() = store.string(COMPLIMENTARY_KEY) == "1"
    val percentOff: Int get() = store.string(PERCENT_KEY)?.toIntOrNull() ?: 0
    val appliedCode: String? get() = store.string(CODE_KEY)?.trim()?.takeIf { it.isNotEmpty() }

    fun remainingGuesses(nowMillis: Long = System.currentTimeMillis()): Int =
        maxOf(0, DAILY_LIMIT - guessCount(nowMillis))

    fun isLocked(nowMillis: Long = System.currentTimeMillis()): Boolean = remainingGuesses(nowMillis) == 0

    fun redeem(raw: String, nowMillis: Long = System.currentTimeMillis()): PromoRedeemResult {
        val code = PromoCatalog.normalize(raw)
        if (code.isEmpty()) return PromoRedeemResult.Empty
        if (isLocked(nowMillis)) return PromoRedeemResult.Locked
        val offer = resolve(code)
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
            PromoOffer.COMPLIMENTARY -> {
                store.set("1", COMPLIMENTARY_KEY)
                store.remove(PERCENT_KEY)
            }
            PromoOffer.PERCENT_OFF -> {
                if (!isComplimentary) store.set(PromoCatalog.CAMPAIGN_PERCENT_OFF.toString(), PERCENT_KEY)
            }
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
