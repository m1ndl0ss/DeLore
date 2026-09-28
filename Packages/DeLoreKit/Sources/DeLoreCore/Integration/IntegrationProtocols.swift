import Foundation

/// Source of conversations and the messages inside them.
///
/// Implementations must page through history rather than materialising it all at once.
public protocol MessageSource: Sendable {
    func account() async throws -> AccountIdentity
    func conversations() async throws -> [ConversationSummary]
    /// Messages of one conversation, oldest first, in pages of at most `pageSize` items.
    func messagePages(in conversation: ConversationID, pageSize: Int) -> AsyncThrowingStream<[DiscoveredMessage], Error>
}

/// What the engine asks an unsend integration to act on.
public struct CleanupTarget: Hashable, Sendable {
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

    public init(item: CleanupItem) {
        self.init(ref: item.ref, authorID: item.authorID, sentAt: item.sentAt, kind: item.kind)
    }
}

public enum UnsendOutcome: Sendable, Equatable {
    case unsent
    /// The message no longer exists (already unsent elsewhere, or removed).
    case alreadyGone
    /// The platform reports that the message wasn't authored by the account owner.
    case notOwned
}

public enum MessagePresence: Sendable, Equatable {
    case present
    case gone
    case notOwned
}

/// Performs the destructive operation. Implementations must never retry `unsend` internally:
/// retry and reconciliation decisions belong to the cleanup engine.
public protocol UnsendService: Sendable {
    func unsend(_ target: CleanupTarget) async throws -> UnsendOutcome
    /// Non-destructive check used to reconcile items whose previous attempt is in doubt.
    func presence(of target: CleanupTarget) async throws -> MessagePresence
}

/// Errors an integration may surface. Associated values never carry user content,
/// identifiers or credentials.
public enum IntegrationError: Error, Equatable, Sendable {
    /// The platform asked us to slow down. `retryAfter` is honoured when provided.
    case rateLimited(retryAfter: TimeInterval?)
    /// The session is no longer valid; the user has to reconnect.
    case sessionExpired
    /// The platform wants the user to verify their account (checkpoint / challenge).
    case verificationRequired
    /// The request never left the device.
    case offline
    /// A transport failure after the request may have reached the server.
    case transportFailure(requestMayHaveBeenApplied: Bool)
    /// 5xx-style failure.
    case serverUnavailable
    /// A response we don't understand. Treated as a reason to stop safely.
    case unexpectedResponse(code: Int?)
    /// The capability isn't available in this build/integration.
    case unavailable
}

/// Stand-in used when no live unsend integration is configured. It never touches the network.
public struct UnavailableUnsendService: UnsendService {
    public init() {}

    public func unsend(_ target: CleanupTarget) async throws -> UnsendOutcome {
        throw IntegrationError.unavailable
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        throw IntegrationError.unavailable
    }
}
