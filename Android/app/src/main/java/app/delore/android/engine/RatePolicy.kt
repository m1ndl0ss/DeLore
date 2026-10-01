package app.delore.android.engine

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

data class RatePolicy(
    val minimumDelay: Double,
    val maximumJitter: Double,
    val burstLimit: Int,
    val burstWindow: Double,
    val hourlyLimit: Int,
    val backoffBase: Double,
    val backoffFactor: Double,
    val backoffMaximum: Double,
    val rateLimitCooldown: Double,
    val rateLimitCooldownMaximum: Double,
    val maxConsecutiveRateLimits: Int,
    val maxRateLimitsPerRun: Int,
    val slowdownFactor: Double,
    val maximumSlowdown: Double,
    val successesToRelax: Int,
    val maxAttemptsPerItem: Int,
    val maxConsecutiveFailures: Int,
) {
    fun estimatedDuration(forItemCount: Int): Double? {
        if (forItemCount <= 0) return 0.0
        val typicalGap = minimumDelay + maximumJitter / 2
        val fromGaps = forItemCount * typicalGap
        if (hourlyLimit <= 0) return fromGaps
        val fromHourlyCap = forItemCount.toDouble() / hourlyLimit * 3_600
        return max(fromGaps, fromHourlyCap)
    }

    companion object {
        val conservative = RatePolicy(
            minimumDelay = 2.0,
            maximumJitter = 0.4,
            burstLimit = 30,
            burstWindow = 60.0,
            hourlyLimit = 1_800,
            backoffBase = 15.0,
            backoffFactor = 2.0,
            backoffMaximum = 15 * 60.0,
            rateLimitCooldown = 10 * 60.0,
            rateLimitCooldownMaximum = 60 * 60.0,
            maxConsecutiveRateLimits = 3,
            maxRateLimitsPerRun = 6,
            slowdownFactor = 2.0,
            maximumSlowdown = 8.0,
            successesToRelax = 50,
            maxAttemptsPerItem = 3,
            maxConsecutiveFailures = 5,
        )

        /** Sample inbox only. Fast enough for review; never used against Instagram. */
        val review = RatePolicy(
            minimumDelay = 0.35,
            maximumJitter = 0.1,
            burstLimit = 200,
            burstWindow = 60.0,
            hourlyLimit = 10_000,
            backoffBase = 0.5,
            backoffFactor = 2.0,
            backoffMaximum = 4.0,
            rateLimitCooldown = 2.0,
            rateLimitCooldownMaximum = 8.0,
            maxConsecutiveRateLimits = 3,
            maxRateLimitsPerRun = 6,
            slowdownFactor = 2.0,
            maximumSlowdown = 4.0,
            successesToRelax = 20,
            maxAttemptsPerItem = 3,
            maxConsecutiveFailures = 5,
        )
    }
}

fun interface RandomSource {
    fun nextUnit(): Double
}

object SystemRandom : RandomSource {
    override fun nextUnit(): Double = Random.nextDouble()
}

class Throttler(val policy: RatePolicy) {
    var slowdown: Double = 1.0
        private set
    var blockedUntil: Long? = null
        private set
    var consecutiveRateLimits: Int = 0
        private set
    var rateLimitsThisRun: Int = 0
        private set
    private val recent = mutableListOf<Long>()
    private var successesSinceSlowdown = 0

    fun delayBeforeNextRequest(nowMillis: Long, random: RandomSource): Double {
        var delay = 0.0
        recent.lastOrNull()?.let { last ->
            val gap = policy.minimumDelay * slowdown + random.nextUnit() * policy.maximumJitter
            delay = max(delay, (last + (gap * 1000).toLong() - nowMillis) / 1000.0)
        }
        if (policy.burstLimit > 0) {
            val windowStart = nowMillis - (policy.burstWindow * 1000).toLong()
            val inWindow = recent.filter { it > windowStart }
            if (inWindow.size >= policy.burstLimit) {
                inWindow.firstOrNull()?.let { oldest ->
                    delay = max(delay, (oldest + (policy.burstWindow * 1000).toLong() - nowMillis) / 1000.0)
                }
            }
        }
        if (policy.hourlyLimit > 0) {
            val hourStart = nowMillis - 3_600_000
            val inHour = recent.filter { it > hourStart }
            if (inHour.size >= policy.hourlyLimit) {
                inHour.firstOrNull()?.let { oldest ->
                    delay = max(delay, (oldest + 3_600_000 - nowMillis) / 1000.0)
                }
            }
        }
        blockedUntil?.let { until ->
            delay = max(delay, (until - nowMillis) / 1000.0)
        }
        return max(0.0, delay)
    }

    fun recordRequest(atMillis: Long) {
        recent.add(atMillis)
        val hourStart = atMillis - 3_600_000
        val firstKept = recent.indexOfFirst { it > hourStart }
        if (firstKept > 0) repeat(firstKept) { recent.removeAt(0) }
        val cap = maxOf(policy.hourlyLimit, policy.burstLimit, 1)
        while (recent.size > cap) recent.removeAt(0)
    }

    fun recordSuccess() {
        consecutiveRateLimits = 0
        if (slowdown <= 1) return
        successesSinceSlowdown += 1
        if (successesSinceSlowdown >= policy.successesToRelax) {
            successesSinceSlowdown = 0
            slowdown = max(1.0, slowdown / policy.slowdownFactor)
        }
    }

    fun recordRateLimit(nowMillis: Long, retryAfterSeconds: Double?, random: RandomSource): Double {
        consecutiveRateLimits += 1
        rateLimitsThisRun += 1
        successesSinceSlowdown = 0
        slowdown = min(policy.maximumSlowdown, slowdown * policy.slowdownFactor)
        val exponent = maxOf(0, consecutiveRateLimits - 1).toDouble()
        val base = min(policy.rateLimitCooldownMaximum, policy.rateLimitCooldown * 2.0.pow(exponent))
        var cooldown = base * (1 + 0.2 * random.nextUnit())
        if (retryAfterSeconds != null && retryAfterSeconds > cooldown) cooldown = retryAfterSeconds
        blockedUntil = nowMillis + (cooldown * 1000).toLong()
        return cooldown
    }

    val shouldStopForRateLimits: Boolean
        get() = consecutiveRateLimits >= policy.maxConsecutiveRateLimits ||
            rateLimitsThisRun >= policy.maxRateLimitsPerRun

    fun beginNewRun() {
        consecutiveRateLimits = 0
        rateLimitsThisRun = 0
    }
}

object Backoff {
    fun delay(attempt: Int, policy: RatePolicy, random: RandomSource): Double {
        val exponent = maxOf(0, attempt - 1).toDouble()
        val capped = min(policy.backoffMaximum, policy.backoffBase * policy.backoffFactor.pow(exponent))
        return capped * (0.5 + 0.5 * random.nextUnit())
    }
}

class ThroughputEstimator(private val smoothing: Double = 0.15) {
    companion object {
        const val MINIMUM_SAMPLES = 5
    }

    private var lastEvent: Long? = null
    var averageSecondsPerItem: Double? = null
        private set
    var samples: Int = 0
        private set

    fun beginSegment(atMillis: Long) {
        lastEvent = atMillis
    }

    fun endSegment() {
        lastEvent = null
    }

    fun recordItem(atMillis: Long) {
        val last = lastEvent
        lastEvent = atMillis
        if (last == null) return
        val elapsed = max(0.0, (atMillis - last) / 1000.0)
        averageSecondsPerItem = averageSecondsPerItem?.let { it + smoothing * (elapsed - it) } ?: elapsed
        samples += 1
    }

    fun estimatedSeconds(remaining: Int): Double? {
        if (remaining <= 0) return 0.0
        val average = averageSecondsPerItem ?: return null
        if (samples < MINIMUM_SAMPLES) return null
        return average * remaining
    }
}

interface EngineClock {
    fun nowMillis(): Long
    suspend fun sleep(seconds: Double)
}

object SystemClock : EngineClock {
    override fun nowMillis(): Long = System.currentTimeMillis()
    override suspend fun sleep(seconds: Double) {
        if (seconds <= 0) return
        kotlinx.coroutines.delay((seconds * 1000).toLong().coerceAtLeast(1))
    }
}
