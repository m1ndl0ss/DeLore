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

    public init(
        id: ConversationID,
        title: String,
        sentByOwner: Int,
        receivedFromOthers: Int,
        firstSentAt: Date?,
        lastSentAt: Date?,
        sentByKind: [MessageKind: Int] = [:],
        ownershipAmbiguous: Bool = false
    ) {
        self.id = id
        self.title = title
        self.sentByOwner = sentByOwner
        self.receivedFromOthers = receivedFromOthers
        self.firstSentAt = firstSentAt
        self.lastSentAt = lastSentAt
        self.sentByKind = sentByKind
        self.ownershipAmbiguous = ownershipAmbiguous
    }

    public var isCleanable: Bool { !ownershipAmbiguous && sentByOwner > 0 }
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

    public var sentByKind: [MessageKind: Int] {
        var totals: [MessageKind: Int] = [:]
        for conversation in cleanableConversations {
            for (kind, count) in conversation.sentByKind { totals[kind, default: 0] += count }
        }
        return totals
    }
}
