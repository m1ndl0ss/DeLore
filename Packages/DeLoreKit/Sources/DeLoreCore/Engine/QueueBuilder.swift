import Foundation

public struct QueueBuildReport: Sendable {
    public let job: CleanupJob
    /// Largest number of items held in memory before being flushed to the store.
    public let peakBufferedItems: Int
    /// Messages seen but excluded because someone else sent them.
    public let excludedNotOwned: Int
    public let excludedDuplicates: Int
    public let excludedAlreadyCleaned: Int
}

/// Streams messages from a source, keeps only those the account owner sent, and writes
/// them to the store in bounded batches — newest first so recent slips go before old history.
public struct QueueBuilder: Sendable {
    private let source: MessageSource
    private let store: JobStore
    private let pageSize: Int
    private let batchSize: Int

    public init(source: MessageSource, store: JobStore, pageSize: Int = 200, batchSize: Int = 500) {
        self.source = source
        self.store = store
        self.pageSize = max(1, pageSize)
        self.batchSize = max(1, batchSize)
    }

    public func build(
        request: CleanupRequest,
        account: AccountIdentity,
        conversations: [ConversationSummary],
        now: Date,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> QueueBuildReport {
        let ledger = try store.loadLedger()
        let targets = Self.targetConversations(for: request.scope, in: conversations)

        var job = CleanupJob(createdAt: now, ownerID: account.ownerID, request: request)
        try store.createJob(job)

        var candidates: [DiscoveredMessage] = []
        var seen = Set<String>()
        var notOwned = 0
        var duplicates = 0
        var alreadyCleaned = 0
        let limit = request.limit ?? Int.max

        for conversation in targets {
            for try await page in source.messagePages(in: conversation.id, pageSize: pageSize) {
                try Task.checkCancellation()
                for message in page {
                    guard message.authorID == account.ownerID else {
                        notOwned += 1
                        continue
                    }
                    guard message.ref.conversationID == conversation.id else { continue }
                    guard request.filter.matches(message) else { continue }
                    let key = message.ref.key
                    guard !ledger.contains(key) else {
                        alreadyCleaned += 1
                        continue
                    }
                    guard seen.insert(key).inserted else {
                        duplicates += 1
                        continue
                    }
                    candidates.append(message)
                }
            }
        }

        // Most recent first — latest messages unsend before older ones.
        candidates.sort { $0.sentAt > $1.sentAt }
        let selected = Array(candidates.prefix(limit))

        var buffer: [CleanupItem] = []
        buffer.reserveCapacity(min(batchSize, selected.count))
        var peak = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try store.appendItems(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        for (index, message) in selected.enumerated() {
            buffer.append(CleanupItem(
                index: index,
                ref: message.ref,
                authorID: message.authorID,
                sentAt: message.sentAt,
                kind: message.kind
            ))
            peak = max(peak, buffer.count)
            if buffer.count >= batchSize {
                try flush()
                onProgress?(index + 1)
            }
        }
        try flush()
        onProgress?(selected.count)

        job.itemCount = selected.count
        try store.updateJob(job)
        return QueueBuildReport(
            job: job,
            peakBufferedItems: peak,
            excludedNotOwned: notOwned,
            excludedDuplicates: duplicates,
            excludedAlreadyCleaned: alreadyCleaned
        )
    }

    /// Scope membership only — used before chats are evaluated (messages may not be loaded yet).
    public static func conversationsInScope(for scope: CleanupScope, in conversations: [ConversationSummary]) -> [ConversationSummary] {
        let selected: [ConversationSummary]
        switch scope {
        case .everything:
            selected = conversations.filter { !$0.ownershipAmbiguous }
        case let .conversations(ids):
            selected = conversations.filter { ids.contains($0.id) && !$0.ownershipAmbiguous }
        }
        return selected.sorted { $0.id < $1.id }
    }

    /// Conversations the request covers that already have loaded, cleanable owner messages.
    public static func targetConversations(for scope: CleanupScope, in conversations: [ConversationSummary]) -> [ConversationSummary] {
        let cleanable = conversations.filter(\.isCleanable)
        let selected: [ConversationSummary]
        switch scope {
        case .everything:
            selected = cleanable
        case let .conversations(ids):
            selected = cleanable.filter { ids.contains($0.id) }
        }
        return selected.sorted { $0.id < $1.id }
    }

    /// Number of messages a request would include, computed from summaries (no I/O).
    public static func estimatedCount(for request: CleanupRequest, in conversations: [ConversationSummary]) -> Int {
        let targets = targetConversations(for: request.scope, in: conversations)
        let total: Int
        if let kinds = request.filter.kinds {
            total = targets.reduce(0) { sum, conversation in
                sum + kinds.reduce(0) { $0 + (conversation.sentByKind[$1] ?? 0) }
            }
        } else {
            total = targets.reduce(0) { $0 + $1.sentByOwner }
        }
        return min(total, request.limit ?? Int.max)
    }
}
