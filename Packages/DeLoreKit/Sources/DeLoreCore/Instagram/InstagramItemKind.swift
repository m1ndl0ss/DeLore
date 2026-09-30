import Foundation

/// Maps Instagram thread items to Retract's four user-facing buckets.
///
/// Instagram's `item_type` is often missing, set to `"text"` on media, or a newer
/// `xma_*` / share name. Counts follow the payload (photo, voice, share, text),
/// not a default of text.
enum InstagramItemKind {
    private static let voiceTypes: Set<String> = ["voice_media", "audio", "voice"]
    private static let shareTypes: Set<String> = [
        "link", "xma_link", "media_share", "reel_share", "story_share", "felix_share",
        "igtv_share", "live_share", "generic_xma", "xma", "hscroll_share", "profile_share",
        "clips_share", "xma_media_share", "xma_reel_share", "xma_story_share", "xma_clips_share",
        "xma_profile", "xma_ig_live"
    ]
    private static let mediaTypes: Set<String> = [
        "media", "raven_media", "animated_media", "visual_media", "clip", "video", "photo",
        "expired_placeholder"
    ]
    private static let textTypes: Set<String> = ["text", "like", "reaction", "emoji_reaction"]
    static let systemTypes: Set<String> = [
        "action_log", "video_call_event", "profile", "live_viewer_invite", "info"
    ]

    static func classify(
        itemType: String?,
        hasVoice: Bool,
        hasPhotoVideo: Bool,
        hasShareOrLink: Bool,
        hasText: Bool
    ) -> MessageKind {
        let type = itemType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if voiceTypes.contains(type) || hasVoice { return .voice }
        if isShare(type) || hasShareOrLink { return .link }
        if mediaTypes.contains(type) || hasPhotoVideo { return .media }
        if textTypes.contains(type) || hasText { return .text }
        return .other
    }

    static func isSystem(_ itemType: String?) -> Bool {
        systemTypes.contains(itemType?.lowercased() ?? "")
    }

    private static func isShare(_ type: String) -> Bool {
        type.hasPrefix("xma") || shareTypes.contains(type)
    }
}
