import Foundation

public enum CleanupScope: Hashable, Codable, Sendable {
    case everything
    case conversations(Set<ConversationID>)
}

public struct CleanupFilter: Hashable, Codable, Sendable {
    public var sentAfter: Date?
    public var sentBefore: Date?
    /// `nil` means every kind.
    public var kinds: Set<MessageKind>?

    public init(sentAfter: Date? = nil, sentBefore: Date? = nil, kinds: Set<MessageKind>? = nil) {
        self.sentAfter = sentAfter
        self.sentBefore = sentBefore
        self.kinds = kinds
    }

    public static let none = CleanupFilter()

    public var isAdvanced: Bool { sentAfter != nil || sentBefore != nil || kinds != nil }

    public func matches(_ message: DiscoveredMessage) -> Bool {
        if let sentAfter, message.sentAt < sentAfter { return false }
        if let sentBefore, message.sentAt > sentBefore { return false }
        if let kinds, !kinds.contains(message.kind) { return false }
        return true
    }
}

public struct CleanupRequest: Hashable, Codable, Sendable {
    public var scope: CleanupScope
    public var filter: CleanupFilter
    /// Upper bound on the number of messages the job may contain (entitlement limit).
    public var limit: Int?

    public init(scope: CleanupScope, filter: CleanupFilter = .none, limit: Int? = nil) {
        self.scope = scope
        self.filter = filter
        self.limit = limit
    }
}

/// Per-item state machine.
///
/// ```
/// discovered → queued → processing → completed
///                 ↑          ├──────→ retryWait → (queued semantics) → processing
///                 │          ├──────→ failed      (attempts exhausted)
///                 │          └──────→ skipped     (not ours / not cleanable)
///  queued | retryWait ──────────────→ cancelled   (job cancelled)
/// ```
/// Pausing is tracked on the job rather than rewriting every pending item.
public enum CleanupItemState: String, Codable, Sendable, CaseIterable {
    case discovered
    case queued
    case processing
    case completed
    case retryWait
    case failed
    case skipped
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped, .cancelled: return true
        case .discovered, .queued, .processing, .retryWait: return false
        }
    }

    public var isPending: Bool { self == .queued || self == .retryWait || self == .discovered }
}

public struct CleanupItem: Hashable, Codable, Sendable {
    public let index: Int
    public let ref: MessageRef
    public let authorID: ParticipantID
    public let sentAt: Date
    public let kind: MessageKind
    public var state: CleanupItemState
    public var attempts: Int
    /// Set when a destructive request may or may not have been applied (timeout, crash,
    /// unexpected response). The engine must verify presence before any new unsend attempt.
    public var needsReconcile: Bool
    public var nextAttemptAt: Date?

    public init(
        index: Int,
        ref: MessageRef,
        authorID: ParticipantID,
        sentAt: Date,
        kind: MessageKind,
        state: CleanupItemState = .queued,
        attempts: Int = 0,
        needsReconcile: Bool = false,
        nextAttemptAt: Date? = nil
    ) {
        self.index = index
        self.ref = ref
        self.authorID = authorID
        self.sentAt = sentAt
        self.kind = kind
        self.state = state
        self.attempts = attempts
        self.needsReconcile = needsReconcile
        self.nextAttemptAt = nextAttemptAt
    }

    enum CodingKeys: String, CodingKey {
        case index = "i", ref = "r", authorID = "a", sentAt = "t", kind = "k"
        case state = "s", attempts = "n", needsReconcile = "v", nextAttemptAt = "w"
    }
}

public enum PauseReason: String, Codable, Sendable, Hashable {
    /// The user tapped pause.
    case user
    /// The app went to the background; resumes automatically when it's back.
    case appInBackground
    /// The app was terminated mid-run; resumes when the user taps resume.
    case interrupted
    case rateLimited
    case sessionExpired
    case verificationRequired
    case repeatedFailures
    case offline
    case unexpectedResponse
    case integrationUnavailable
    /// Progress couldn't be saved, so no further destructive request is sent.
    case storageFailure

    /// Reasons where we must not resume without the user doing something first.
    public var requiresUserAction: Bool {
        switch self {
        case .sessionExpired, .verificationRequired, .integrationUnavailable: return true
        case .user, .appInBackground, .interrupted, .rateLimited, .repeatedFailures, .offline, .unexpectedResponse,
             .storageFailure:
            return false
        }
    }
}

public enum JobStatus: Hashable, Codable, Sendable {
    case ready
    case running
    case paused(PauseReason)
    case completed
    case cancelled

    public var isFinished: Bool { self == .completed || self == .cancelled }

    public var pauseReason: PauseReason? {
        if case let .paused(reason) = self { return reason }
        return nil
    }
}

public struct CleanupJob: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let ownerID: ParticipantID
    public let request: CleanupRequest
    /// Timestamp of the user's explicit confirmation. The engine refuses to run without it.
    public var authorizedAt: Date?
    public var status: JobStatus
    /// Earliest time an automatic resume is allowed after a rate-limit pause.
    public var resumeNotBefore: Date?
    public var itemCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        ownerID: ParticipantID,
        request: CleanupRequest,
        authorizedAt: Date? = nil,
        status: JobStatus = .ready,
        resumeNotBefore: Date? = nil,
        itemCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.ownerID = ownerID
        self.request = request
        self.authorizedAt = authorizedAt
        self.status = status
        self.resumeNotBefore = resumeNotBefore
        self.itemCount = itemCount
    }
}

public struct CleanupProgress: Hashable, Sendable {
    public let jobID: UUID
    public let status: JobStatus
    public let total: Int
    public let completed: Int
    public let skipped: Int
    public let failed: Int
    public let cancelled: Int
    public let estimatedSecondsRemaining: TimeInterval?
    public let resumeNotBefore: Date?

    public init(
        jobID: UUID,
        status: JobStatus,
        total: Int,
        completed: Int,
        skipped: Int,
        failed: Int,
        cancelled: Int,
        estimatedSecondsRemaining: TimeInterval?,
        resumeNotBefore: Date?
    ) {
        self.jobID = jobID
        self.status = status
        self.total = total
        self.completed = completed
        self.skipped = skipped
        self.failed = failed
        self.cancelled = cancelled
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.resumeNotBefore = resumeNotBefore
    }

    /// Items that reached a terminal state.
    public var processed: Int { completed + skipped + failed + cancelled }
    public var remaining: Int { max(0, total - processed) }

    /// Fraction in 0...1, based on items that reached a terminal state.
    public var fraction: Double {
        guard total > 0 else { return status == .completed ? 1 : 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }
}
