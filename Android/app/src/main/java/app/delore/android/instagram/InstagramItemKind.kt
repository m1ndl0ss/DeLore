package app.delore.android.instagram

import app.delore.android.domain.MessageKind
import org.json.JSONObject

/**
 * Maps Instagram thread items to Retract's four user-facing buckets.
 *
 * Instagram's `item_type` is often missing, set to `"text"` on media, or a newer
 * `xma_*` / share name. Counts must follow the payload (photo, voice, share, text),
 * not a default of text.
 */
object InstagramItemKind {
    private val voiceTypes = setOf("voice_media", "audio", "voice")
    private val shareTypes = setOf(
        "link", "xma_link", "media_share", "reel_share", "story_share", "felix_share",
        "igtv_share", "live_share", "generic_xma", "xma", "hscroll_share", "profile_share",
        "clips_share", "xma_media_share", "xma_reel_share", "xma_story_share", "xma_clips_share",
        "xma_profile", "xma_ig_live",
    )
    private val mediaTypes = setOf(
        "media", "raven_media", "animated_media", "visual_media", "clip", "video", "photo",
        "expired_placeholder",
    )
    private val textTypes = setOf("text", "like", "reaction", "emoji_reaction")
    private val systemTypes = setOf("action_log", "video_call_event", "profile", "live_viewer_invite", "info")

    fun declaredType(obj: JSONObject): String {
        for (key in listOf("item_type", "itemType")) {
            if (!obj.has(key) || obj.isNull(key)) continue
            val value = obj.optString(key).trim()
            if (value.isNotEmpty() && !value.equals("null", ignoreCase = true)) return value.lowercase()
        }
        return ""
    }

    fun of(obj: JSONObject): MessageKind {
        val type = declaredType(obj)
        val hasVoice = present(obj, "voice_media") || present(obj, "audio")
        val hasShare = present(obj, "link") || present(obj, "xma") || present(obj, "media_share") ||
            present(obj, "reel_share") || present(obj, "story_share") || present(obj, "felix_share")
        val hasPhotoVideo = present(obj, "visual_media") || present(obj, "raven_media") ||
            present(obj, "animated_media") || present(obj, "clip") || present(obj, "media")
        val hasText = present(obj, "text")
        return classify(type, hasVoice, hasPhotoVideo, hasShare, hasText)
    }

    fun classify(
        itemType: String?,
        hasVoice: Boolean,
        hasPhotoVideo: Boolean,
        hasShareOrLink: Boolean,
        hasText: Boolean,
    ): MessageKind {
        val type = itemType?.trim()?.lowercase().orEmpty()
        if (type in voiceTypes || hasVoice) return MessageKind.VOICE
        if (isShare(type) || hasShareOrLink) return MessageKind.LINK
        if (type in mediaTypes || hasPhotoVideo) return MessageKind.MEDIA
        if (type in textTypes || hasText) return MessageKind.TEXT
        return MessageKind.OTHER
    }

    fun isSystem(type: String): Boolean = type.lowercase() in systemTypes

    private fun isShare(type: String): Boolean = type.startsWith("xma") || type in shareTypes

    private fun present(obj: JSONObject, key: String): Boolean = obj.has(key) && !obj.isNull(key)
}
