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
            let threads: [ThreadStub]
            let hasOlder: Bool?
            let oldestCursor: String?

            enum CodingKeys: String, CodingKey {
                case threads
                case hasOlder = "has_older"
                case oldestCursor = "oldest_cursor"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                threads = (try container.decodeIfPresent(LossyArray<ThreadStub>.self, forKey: .threads))?.elements ?? []
                hasOlder = try container.decodeIfPresent(Bool.self, forKey: .hasOlder)
                let cursor = try container.decodeIfPresent(String.self, forKey: .oldestCursor)
                oldestCursor = cursor?.isEmpty == false ? cursor : nil
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
                case threadV2ID = "thread_v2_id"
                case id
                case threadTitle = "thread_title"
                case users
                case hasOlder = "has_older"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                guard let id = try container.decodeIfPresent(FlexibleID.self, forKey: .threadID)
                    ?? container.decodeIfPresent(FlexibleID.self, forKey: .threadV2ID)
                    ?? container.decodeIfPresent(FlexibleID.self, forKey: .id),
                    !id.rawValue.isEmpty
                else {
                    throw DecodingError.keyNotFound(
                        CodingKeys.threadID,
                        .init(codingPath: decoder.codingPath, debugDescription: "thread id")
                    )
                }
                threadID = id
                threadTitle = try container.decodeIfPresent(String.self, forKey: .threadTitle)
                users = try container.decodeIfPresent([User].self, forKey: .users)
                hasOlder = try container.decodeIfPresent(Bool.self, forKey: .hasOlder)
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
        let webMessageID: String?

        private enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case clientContext = "client_context"
            case messageID = "message_id"
            case userID = "user_id"
            case timestamp
            case itemType = "item_type"
            case itemTypeCamel = "itemType"
            case isSentByViewer = "is_sent_by_viewer"
            case text, media, clip, link, xma, audio
            case visualMedia = "visual_media"
            case voiceMedia = "voice_media"
            case animatedMedia = "animated_media"
            case ravenMedia = "raven_media"
            case mediaShare = "media_share"
            case reelShare = "reel_share"
            case storyShare = "story_share"
            case felixShare = "felix_share"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decodeIfPresent(FlexibleID.self, forKey: .itemID)
                ?? container.decodeIfPresent(FlexibleID.self, forKey: .clientContext)
            itemID = id?.rawValue ?? ""
            authorID = try container.decodeIfPresent(FlexibleID.self, forKey: .userID)?.rawValue
            let rawTimestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
            sentAt = Self.date(from: rawTimestamp)
            let type = (try container.decodeIfPresent(String.self, forKey: .itemType)
                ?? container.decodeIfPresent(String.self, forKey: .itemTypeCamel))
            kind = InstagramItemKind.classify(
                itemType: type,
                hasVoice: container.contains(.voiceMedia) || container.contains(.audio),
                hasPhotoVideo: container.contains(.visualMedia) || container.contains(.ravenMedia)
                    || container.contains(.animatedMedia) || container.contains(.clip)
                    || container.contains(.media),
                hasShareOrLink: container.contains(.link) || container.contains(.xma)
                    || container.contains(.mediaShare) || container.contains(.reelShare)
                    || container.contains(.storyShare) || container.contains(.felixShare),
                hasText: container.contains(.text)
            )
            isSystem = InstagramItemKind.isSystem(type)
            sentByViewer = try container.decodeIfPresent(Bool.self, forKey: .isSentByViewer)
            let message = try container.decodeIfPresent(FlexibleID.self, forKey: .messageID)?.rawValue
            let client = try container.decodeIfPresent(FlexibleID.self, forKey: .clientContext)?.rawValue
            // Prefer an explicit mid.$…; nested blobs are filled in parseThread via findMid.
            webMessageID = [message, client].compactMap { $0 }.first { $0.hasPrefix("mid.") }
        }

        func with(webMessageID newMid: String) -> Item {
            Item(
                itemID: itemID,
                authorID: authorID,
                sentAt: sentAt,
                kind: kind,
                isSystem: isSystem,
                sentByViewer: sentByViewer,
                webMessageID: newMid
            )
        }

        init(
            itemID: String,
            authorID: String?,
            sentAt: Date,
            kind: MessageKind,
            isSystem: Bool,
            sentByViewer: Bool?,
            webMessageID: String?
        ) {
            self.itemID = itemID
            self.authorID = authorID
            self.sentAt = sentAt
            self.kind = kind
            self.isSystem = isSystem
            self.sentByViewer = sentByViewer
            self.webMessageID = webMessageID
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

    }

    static func title(for stub: InboxPage.ThreadStub, ownerID: String) -> String {
        let others = (stub.users ?? []).compactMap { user -> String? in
            guard user.pk?.rawValue != ownerID else { return nil }
            if let username = user.username, !username.isEmpty { return "@\(username)" }
            if let name = user.fullName, !name.isEmpty { return name }
            return nil
        }
        if !others.isEmpty { return others.joined(separator: ", ") }
        if let title = stub.threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != "Instagram User" {
            return title
        }
        return "Chat"
    }

    static func topKeys(_ body: Data) -> String {
        if body.isEmpty { return "empty" }
        if looksLikeHTML(body) { return "html" }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "not-json" }
        return object.keys.prefix(12).joined(separator: ",")
    }

    static func parseInbox(_ body: Data) throws -> InboxPage {
        let quoted = quoteOversizedNumericIDs(body)
        let root = try JSONSerialization.jsonObject(with: quoted)
        guard let object = root as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "inbox root"))
        }
        let payload: Data
        if object["inbox"] == nil, let data = object["data"] as? [String: Any], data["inbox"] != nil {
            payload = try JSONSerialization.data(withJSONObject: data)
        } else {
            payload = quoted
        }
        let page = try JSONDecoder().decode(InboxPage.self, from: payload)
        guard page.inbox != nil else {
            throw DecodingError.keyNotFound(
                InboxPage.Inbox.CodingKeys.threads,
                .init(codingPath: [], debugDescription: "inbox")
            )
        }
        return page
    }

    static func parseThread(_ body: Data) throws -> ThreadPage {
        let quoted = quoteOversizedNumericIDs(body)
        let root = try JSONSerialization.jsonObject(with: quoted)
        guard let object = root as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "thread root"))
        }
        let threadObject: [String: Any]?
        let payload: Data
        if object["thread"] == nil, let data = object["data"] as? [String: Any], data["thread"] != nil {
            threadObject = data["thread"] as? [String: Any]
            payload = try JSONSerialization.data(withJSONObject: data)
        } else {
            threadObject = object["thread"] as? [String: Any]
            payload = quoted
        }
        let page = try JSONDecoder().decode(ThreadPage.self, from: payload)
        guard let thread = page.thread else {
            throw DecodingError.keyNotFound(
                ThreadPage.Thread.CodingKeys.items,
                .init(codingPath: [], debugDescription: "thread")
            )
        }
        let rawItems = threadObject?["items"] as? [[String: Any]] ?? []
        let items = thread.items ?? []
        let enriched: [Item] = items.enumerated().map { index, item in
            if let mid = item.webMessageID, mid.hasPrefix("mid.") { return item }
            guard index < rawItems.count, let mid = findMid(rawItems[index]) else { return item }
            return item.with(webMessageID: mid)
        }
        let enrichedThread = ThreadPage.Thread(
            threadID: thread.threadID,
            threadTitle: thread.threadTitle,
            users: thread.users,
            items: enriched,
            hasOlder: thread.hasOlder,
            oldestCursor: thread.oldestCursor
        )
        return ThreadPage(thread: enrichedThread, status: page.status)
    }

    /// Walk nested JSON for a `mid.$…` string Instagram sometimes nests under media/xma blobs.
    static func findMid(_ value: Any?, depth: Int = 0) -> String? {
        guard depth <= 4, let value else { return nil }
        if let string = value as? String, string.hasPrefix("mid.") { return string }
        if let dict = value as? [String: Any] {
            for child in dict.values {
                if let found = findMid(child, depth: depth + 1) { return found }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = findMid(child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    static func quoteOversizedNumericIDs(_ body: Data) -> Data {
        guard var text = String(data: body, encoding: .utf8) else { return body }
        let pattern = "\"(item_id|thread_id|thread_v2_id|user_id|pk|client_context|message_id|id)\"\\s*:\\s*(\\d{16,})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return body }
        let range = NSRange(text.startIndex..., in: text)
        text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\"$1\":\"$2\"")
        return Data(text.utf8)
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(32), encoding: .utf8)?.lowercased() else { return false }
        return prefix.contains("<!doctype") || prefix.contains("<html")
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var parsed: [Element] = []
        while !container.isAtEnd {
            if (try? container.decodeNil()) == true { continue }
            do {
                parsed.append(try container.decode(Element.self))
            } catch {
                _ = try container.decode(JSONSkip.self)
            }
        }
        elements = parsed
    }
}

private struct JSONSkip: Decodable {
    private struct Key: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int?
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    init(from decoder: Decoder) throws {
        if (try? decoder.container(keyedBy: Key.self)) != nil { return }
        if var nested = try? decoder.unkeyedContainer() {
            while !nested.isAtEnd { _ = try nested.decode(JSONSkip.self) }
            return
        }
        _ = try decoder.singleValueContainer()
    }
}
