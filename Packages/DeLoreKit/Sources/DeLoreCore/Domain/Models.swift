import Foundation

/// Stable identifier of a conversation inside the connected account.
public struct ConversationID: Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: ConversationID, rhs: ConversationID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identifier of one participant. For export-based discovery this is derived from the
/// participant name as it appears in the export; live integrations can use a real account id.
public struct ParticipantID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Uniquely identifies a message: conversation + message id within it.
public struct MessageRef: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    public let messageID: String

    public init(conversationID: ConversationID, messageID: String) {
        self.conversationID = conversationID
        self.messageID = messageID
    }

    /// Compact key used for de-duplication and the cleaned-message ledger.
    public var key: String { conversationID.rawValue + "|" + messageID }

    enum CodingKeys: String, CodingKey {
        case conversationID = "c"
        case messageID = "m"
    }
}

public enum MessageKind: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    case text
    case media
    case link
    case voice
    case other
}

/// A message as reported by a discovery source. Contains no message content by design.
public struct DiscoveredMessage: Hashable, Sendable {
    public let ref: MessageRef
    public let authorID: ParticipantID
    public let sentAt: Date
    public let kind: MessageKind

    public init(ref: MessageRef, authorID: ParticipantID, sentAt: Date, kind: MessageKind) {
        self.ref = ref
        self.authorID = authorID
        self.sentAt = sentAt
        self.kind = kind
    }
}

public struct AccountIdentity: Hashable, Codable, Sendable {
    public let ownerID: ParticipantID
    public let displayName: String

    public init(ownerID: ParticipantID, displayName: String) {
        self.ownerID = ownerID
        self.displayName = displayName
    }
}

/// Aggregated, content-free description of a conversation.
public struct ConversationSummary: Hashable, Codable, Sendable, Identifiable {
    public let id: ConversationID
    public let title: String
    public let sentByOwner: Int
    public let receivedFromOthers: Int
    public let firstSentAt: Date?
    public let lastSentAt: Date?
    public let sentByKind: [MessageKind: Int]
    /// True when ownership can't be determined reliably (e.g. another participant shares the
    /// owner's display name). Such conversations are never offered for cleanup.
    public let ownershipAmbiguous: Bool
    /// False until this chat's history has been read on-device. Listing who you talk to
    /// does not load messages.
    public let messagesLoaded: Bool

    public init(
        id: ConversationID,
        title: String,
        sentByOwner: Int,
        receivedFromOthers: Int,
        firstSentAt: Date?,
        lastSentAt: Date?,
        sentByKind: [MessageKind: Int] = [:],
        ownershipAmbiguous: Bool = false,
        messagesLoaded: Bool = true
    ) {
        self.id = id
        self.title = title
        self.sentByOwner = sentByOwner
        self.receivedFromOthers = receivedFromOthers
        self.firstSentAt = firstSentAt
        self.lastSentAt = lastSentAt
        self.sentByKind = sentByKind
        self.ownershipAmbiguous = ownershipAmbiguous
        self.messagesLoaded = messagesLoaded
    }

    public var isCleanable: Bool { messagesLoaded && !ownershipAmbiguous && sentByOwner > 0 }

    enum CodingKeys: String, CodingKey {
        case id, title, sentByOwner, receivedFromOthers, firstSentAt, lastSentAt, sentByKind, ownershipAmbiguous, messagesLoaded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ConversationID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sentByOwner = try container.decode(Int.self, forKey: .sentByOwner)
        receivedFromOthers = try container.decode(Int.self, forKey: .receivedFromOthers)
        firstSentAt = try container.decodeIfPresent(Date.self, forKey: .firstSentAt)
        lastSentAt = try container.decodeIfPresent(Date.self, forKey: .lastSentAt)
        sentByKind = try container.decodeIfPresent([MessageKind: Int].self, forKey: .sentByKind) ?? [:]
        ownershipAmbiguous = try container.decodeIfPresent(Bool.self, forKey: .ownershipAmbiguous) ?? false
        messagesLoaded = try container.decodeIfPresent(Bool.self, forKey: .messagesLoaded) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(sentByOwner, forKey: .sentByOwner)
        try container.encode(receivedFromOthers, forKey: .receivedFromOthers)
        try container.encodeIfPresent(firstSentAt, forKey: .firstSentAt)
        try container.encodeIfPresent(lastSentAt, forKey: .lastSentAt)
        try container.encode(sentByKind, forKey: .sentByKind)
        try container.encode(ownershipAmbiguous, forKey: .ownershipAmbiguous)
        try container.encode(messagesLoaded, forKey: .messagesLoaded)
    }
}

/// Library-level totals shown on the home screen.
public struct LibraryOverview: Hashable, Sendable {
    public let conversations: [ConversationSummary]

    public init(conversations: [ConversationSummary]) {
        self.conversations = conversations
    }

    public var sentByOwner: Int { conversations.filter(\.isCleanable).reduce(0) { $0 + $1.sentByOwner } }
    public var receivedFromOthers: Int { conversations.reduce(0) { $0 + $1.receivedFromOthers } }
    public var cleanableConversations: [ConversationSummary] { conversations.filter(\.isCleanable) }
    public var unreadConversations: [ConversationSummary] { conversations.filter { !$0.messagesLoaded } }

    public var sentByKind: [MessageKind: Int] {
        var totals: [MessageKind: Int] = [:]
        for conversation in cleanableConversations {
            for (kind, count) in conversation.sentByKind { totals[kind, default: 0] += count }
        }
        return totals
    }
}

/// Live progress while paging Instagram Direct into the local library.
public struct InboxReadProgress: Sendable, Equatable {
    public var chatsFound: Int
    public var chatsRead: Int
    public var chatsTotal: Int?
    public var sendsFound: Int
    public var currentTitle: String?

    public init(
        chatsFound: Int = 0,
        chatsRead: Int = 0,
        chatsTotal: Int? = nil,
        sendsFound: Int = 0,
        currentTitle: String? = nil
    ) {
        self.chatsFound = chatsFound
        self.chatsRead = chatsRead
        self.chatsTotal = chatsTotal
        self.sendsFound = sendsFound
        self.currentTitle = currentTitle
    }

    public var isListing: Bool { chatsTotal == nil }
    public var isComplete: Bool {
        guard let chatsTotal else { return false }
        return chatsRead >= chatsTotal
    }

    public var displayChat: String? {
        let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title.caseInsensitiveCompare("Instagram User") != .orderedSame else { return nil }
        if title.count > 28 { return String(title.prefix(27)) + "…" }
        return title
    }

    public var fraction: Double {
        guard let total = chatsTotal else {
            return min(0.16, 0.05 + Double(min(chatsFound, 80)) * 0.0014)
        }
        guard total > 0 else { return 1 }
        let working = chatsRead < total ? 0.35 : 0
        return min(1, max(0.18, 0.18 + 0.82 * ((Double(chatsRead) + working) / Double(total))))
    }
}
