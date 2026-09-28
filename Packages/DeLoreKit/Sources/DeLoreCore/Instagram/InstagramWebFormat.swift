import Foundation

/// Decodes Instagram website inbox JSON without materialising message text.
enum InstagramWebFormat {
    struct FlexibleID: Decodable, Hashable, Sendable {
        let rawValue: String

        init(_ rawValue: String) { self.rawValue = rawValue }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                rawValue = value
            } else if let value = try? container.decode(Int64.self) {
                rawValue = String(value)
            } else if let value = try? container.decode(Int.self) {
                rawValue = String(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "id")
            }
        }
    }

    struct InboxPage: Decodable {
        let inbox: Inbox?
        let viewer: Viewer?
        let status: String?

        struct Inbox: Decodable {
            let threads: [ThreadStub]?
            let hasOlder: Bool?
            let oldestCursor: String?

            enum CodingKeys: String, CodingKey {
                case threads
                case hasOlder = "has_older"
                case oldestCursor = "oldest_cursor"
            }
        }

        struct Viewer: Decodable {
            let pk: FlexibleID?
            let username: String?
        }

        struct ThreadStub: Decodable {
            let threadID: FlexibleID
            let threadTitle: String?
            let users: [User]?
            let hasOlder: Bool?

            enum CodingKeys: String, CodingKey {
                case threadID = "thread_id"
                case threadTitle = "thread_title"
                case users
                case hasOlder = "has_older"
            }
        }

        struct User: Decodable {
            let pk: FlexibleID?
            let username: String?
            let fullName: String?

            enum CodingKeys: String, CodingKey {
                case pk, username
                case fullName = "full_name"
            }
        }
    }

    struct ThreadPage: Decodable {
        let thread: Thread?
        let status: String?

        struct Thread: Decodable {
            let threadID: FlexibleID?
            let threadTitle: String?
            let users: [InboxPage.User]?
            let items: [Item]?
            let hasOlder: Bool?
            let oldestCursor: String?

            enum CodingKeys: String, CodingKey {
                case threadID = "thread_id"
                case threadTitle = "thread_title"
                case users, items
                case hasOlder = "has_older"
                case oldestCursor = "oldest_cursor"
            }
        }
    }

    struct Item: Decodable {
        let itemID: String
        let authorID: String?
        let sentAt: Date
        let kind: MessageKind
        let isSystem: Bool
        let sentByViewer: Bool?

        private enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case userID = "user_id"
            case timestamp
            case itemType = "item_type"
            case isSentByViewer = "is_sent_by_viewer"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(FlexibleID.self, forKey: .itemID)
            itemID = id.rawValue
            authorID = try container.decodeIfPresent(FlexibleID.self, forKey: .userID)?.rawValue
            let rawTimestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
            sentAt = Self.date(from: rawTimestamp)
            let type = (try container.decodeIfPresent(String.self, forKey: .itemType) ?? "text").lowercased()
            kind = Self.kind(for: type)
            isSystem = Self.isSystem(type)
            sentByViewer = try container.decodeIfPresent(Bool.self, forKey: .isSentByViewer)
        }

        /// Direct timestamps are microseconds when they're 16+ digits.
        private static func date(from raw: Int64) -> Date {
            if raw > 10_000_000_000_000 {
                return Date(timeIntervalSince1970: Double(raw) / 1_000_000)
            }
            if raw > 10_000_000_000 {
                return Date(timeIntervalSince1970: Double(raw) / 1_000)
            }
            return Date(timeIntervalSince1970: Double(raw))
        }

        private static func kind(for type: String) -> MessageKind {
            switch type {
            case "voice_media", "audio": return .voice
            case "media", "raven_media", "animated_media", "clip", "media_share", "reel_share",
                 "story_share", "felix_share", "xma_media_share", "generic_xma": return .media
            case "link", "xma_link": return .link
            case "text", "placeholder": return .text
            default: return .other
            }
        }

        private static func isSystem(_ type: String) -> Bool {
            ["action_log", "video_call_event", "profile", "live_viewer_invite", "info"].contains(type)
        }
    }

    static func title(for stub: InboxPage.ThreadStub, ownerID: String) -> String {
        if let title = stub.threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != "Instagram User" {
            return title
        }
        let others = (stub.users ?? []).compactMap { user -> String? in
            guard user.pk?.rawValue != ownerID else { return nil }
            if let name = user.fullName, !name.isEmpty { return name }
            return user.username
        }
        return others.isEmpty ? "Chat" : others.joined(separator: ", ")
    }
}
