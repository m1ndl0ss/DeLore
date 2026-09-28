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

class PassLedger(private val store: SecretStore) {
    companion object {
        const val PASSES = "entitlements.passes"
        const val PROCESSED = "entitlements.processedTransactions"
        const val FREE_USED = "entitlements.freeUsed"
        val preservedKeys = listOf(PASSES, PROCESSED, FREE_USED)
    }

    val passes: Int get() = integer(PASSES)
    val freeMessagesUsed: Int get() = integer(FREE_USED)

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

    fun addFreeUsage(count: Int) {
        if (count <= 0) return
        store.set((freeMessagesUsed + count).toString(), FREE_USED)
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
