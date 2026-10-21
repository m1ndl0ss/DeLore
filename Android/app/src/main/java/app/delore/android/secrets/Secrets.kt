package app.delore.android.secrets

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

interface SecretStore {
    fun string(key: String): String?
    fun data(key: String): ByteArray?
    fun set(value: String, key: String)
    fun set(value: ByteArray, key: String)
    fun remove(key: String)
    fun wipePreserving(keys: Collection<String>)
}

class EncryptedSecretStore(context: Context) : SecretStore {
    private val prefs: SharedPreferences

    init {
        val master = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            context,
            "delore.secrets",
            master,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    override fun string(key: String): String? = prefs.getString(key, null)

    override fun data(key: String): ByteArray? = string(key)?.let { android.util.Base64.decode(it, android.util.Base64.NO_WRAP) }

    override fun set(value: String, key: String) {
        prefs.edit().putString(key, value).apply()
    }

    override fun set(value: ByteArray, key: String) {
        set(android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP), key)
    }

    override fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    override fun wipePreserving(keys: Collection<String>) {
        val keep = keys.associateWith { prefs.getString(it, null) }
        prefs.edit().clear().apply()
        val editor = prefs.edit()
        keep.forEach { (k, v) -> if (v != null) editor.putString(k, v) }
        editor.apply()
    }
}

class SessionVault(private val store: SecretStore) {
    private val key = "integration.session"

    fun save(sessionJson: String) = store.set(sessionJson, key)
    fun load(): String? = store.string(key)
    fun clear() = store.remove(key)
}

/**
 * Unused one-time passes and the free allowance.
 *
 * Free usage is per Instagram account, kept locally and max-merged with the Retract worker
 * so the same account shares one counter across devices. Never cleared on logout.
 */
class PassLedger(private val store: SecretStore) {
    companion object {
        const val PASSES = "entitlements.passes"
        const val PROCESSED = "entitlements.processedTransactions"
        /** Legacy device-wide counter; migrated into [FREE_USED_BY_ACCOUNT] on first account touch. */
        const val FREE_USED = "entitlements.freeUsed"
        const val FREE_USED_BY_ACCOUNT = "entitlements.freeUsedByAccount"
        val preservedKeys = listOf(PASSES, PROCESSED, FREE_USED, FREE_USED_BY_ACCOUNT)
    }

    val passes: Int get() = integer(PASSES)

    /** Free usage for a signed-in Instagram account. Null / empty → 0. */
    fun freeMessagesUsed(forUserId: String?): Int {
        val userId = normalize(forUserId) ?: return 0
        migrateLegacyIfNeeded(userId)
        return usageByAccount()[userId] ?: 0
    }

    private fun integer(key: String): Int = store.string(key)?.toIntOrNull() ?: 0

    fun credit(transactionID: String): Boolean {
        val processed = processedTransactions().toMutableSet()
        if (!processed.add(transactionID)) return false
        store.set((passes + 1).toString(), PASSES)
        store.set(processed.joinToString("\n"), PROCESSED)
        return true
    }

    fun consumePass(): Boolean {
        val current = passes
        if (current <= 0) return false
        store.set((current - 1).toString(), PASSES)
        return true
    }

    fun addFreeUsage(count: Int, accountUserId: String?) {
        if (count <= 0) return
        val userId = normalize(accountUserId) ?: return
        migrateLegacyIfNeeded(userId)
        val map = usageByAccount().toMutableMap()
        map[userId] = (map[userId] ?: 0) + count
        saveUsage(map)
    }

    /** Raises local usage to at least [remote] for this account (cross-device max-merge). */
    fun mergeRemoteFreeUsage(remote: Int, accountUserId: String?): Int {
        val userId = normalize(accountUserId) ?: return 0
        migrateLegacyIfNeeded(userId)
        val map = usageByAccount().toMutableMap()
        val merged = maxOf(map[userId] ?: 0, maxOf(0, remote))
        map[userId] = merged
        saveUsage(map)
        return merged
    }

    private fun normalize(userId: String?): String? =
        userId?.trim()?.takeIf { it.isNotEmpty() }

    private fun usageByAccount(): Map<String, Int> {
        val raw = store.string(FREE_USED_BY_ACCOUNT)?.takeIf { it.isNotBlank() } ?: return emptyMap()
        return runCatching {
            val json = org.json.JSONObject(raw)
            buildMap {
                val keys = json.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    put(key, json.optInt(key, 0))
                }
            }
        }.getOrDefault(emptyMap())
    }

    private fun saveUsage(map: Map<String, Int>) {
        val json = org.json.JSONObject()
        map.forEach { (key, value) -> json.put(key, value) }
        store.set(json.toString(), FREE_USED_BY_ACCOUNT)
    }

    /** One-time: fold the old device-wide integer into this account, then drop the legacy key. */
    private fun migrateLegacyIfNeeded(userId: String) {
        val legacy = integer(FREE_USED)
        if (legacy <= 0) return
        val map = usageByAccount().toMutableMap()
        if (userId !in map) {
            map[userId] = legacy
            saveUsage(map)
        }
        store.remove(FREE_USED)
    }

    private fun processedTransactions(): Set<String> =
        store.string(PROCESSED)?.lines()?.filter { it.isNotEmpty() }?.toSet() ?: emptySet()
}

enum class CleanupBilling { FREE, PASS, PRO }

object BillingLedger {
    private const val PREFIX = "cleanup.billing."

    fun record(prefs: SharedPreferences, billing: CleanupBilling, jobID: String) {
        prefs.edit().putString(PREFIX + jobID, billing.name).apply()
    }

    fun billing(prefs: SharedPreferences, jobID: String): CleanupBilling? =
        prefs.getString(PREFIX + jobID, null)?.let { runCatching { CleanupBilling.valueOf(it) }.getOrNull() }

    fun clear(prefs: SharedPreferences, jobID: String) {
        prefs.edit().remove(PREFIX + jobID).apply()
    }

    fun clearAll(prefs: SharedPreferences) {
        val editor = prefs.edit()
        prefs.all.keys.filter { it.startsWith(PREFIX) }.forEach { editor.remove(it) }
        editor.apply()
    }
}
