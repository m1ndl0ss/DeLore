package app.delore.android.persist

import android.content.SharedPreferences
import app.delore.android.domain.ConversationID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class InboxWorkSnapshot(
    val kind: Kind,
    val ids: List<String> = emptyList(),
    val titles: Map<String, String> = emptyMap(),
    val retractIds: List<String> = emptyList(),
) {
    enum class Kind { LIST, LOAD }

    val conversationIds: List<ConversationID> get() = ids.map(::ConversationID)
    val retract: Set<ConversationID> get() = retractIds.map(::ConversationID).toSet()
}

class InboxWorkStore(
    private val prefs: SharedPreferences,
    private val json: Json,
) {
    fun save(snapshot: InboxWorkSnapshot) {
        prefs.edit().putString(KEY, json.encodeToString(snapshot)).apply()
    }

    fun load(): InboxWorkSnapshot? {
        val raw = prefs.getString(KEY, null) ?: return null
        return runCatching { json.decodeFromString<InboxWorkSnapshot>(raw) }.getOrNull()
    }

    fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    companion object {
        const val KEY = "inbox.work"
    }
}
