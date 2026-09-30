import Foundation

/// Pages the authenticated inbox and writes a content-free local library.
///
/// One thread is held in memory at a time. Listing requests are spaced out so discovery
/// doesn't look like a burst of unsends — still far slower than a typical browser would go.
public struct InstagramInboxSync: Sendable {
    public var pageSize: Int
    public var listingDelay: TimeInterval
    public var clock: EngineClock

    private let client: InstagramAPIClient
    private let library: LocalLibraryStore

    public init(
        client: InstagramAPIClient,
        library: LocalLibraryStore,
        pageSize: Int = 20,
        listingDelay: TimeInterval = 0.4,
        clock: EngineClock = SystemClock()
    ) {
        self.client = client
        self.library = library
        self.pageSize = max(1, pageSize)
        self.listingDelay = max(0, listingDelay)
        self.clock = clock
    }

    public func run(
        session: InstagramWebSession,
        onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil
    ) async throws -> LibraryOverview {
        let listed = try await list(session: session, onProgress: onProgress)
        return try await load(session: session, ids: listed.conversations.map(\.id), onProgress: onProgress)
    }

    public func list(
        session: InstagramWebSession,
        onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil
    ) async throws -> LibraryOverview {
        let ownerID = session.userID
        var displayName = session.displayName
        var stubs: [InstagramWebFormat.InboxPage.ThreadStub] = []
        var seen = Set<String>()
        var cursor: String?
        var inboxHasOlder = true
        onProgress?(InboxReadProgress())

        while inboxHasOlder {
            try Task.checkCancellation()
            let page = try await fetchInbox(cursor: cursor)
            if displayName == nil, let username = page.viewer?.username, !username.isEmpty {
                displayName = username
            }
            for stub in page.inbox?.threads ?? [] where seen.insert(stub.threadID.rawValue).inserted {
                stubs.append(stub)
            }
            inboxHasOlder = page.inbox?.hasOlder ?? false
            cursor = page.inbox?.oldestCursor
            if cursor == nil { inboxHasOlder = false }
            onProgress?(InboxReadProgress(chatsFound: stubs.count))
            if listingDelay > 0 { try await clock.sleep(for: listingDelay) }
        }

        let account = AccountIdentity(ownerID: ParticipantID("ig:" + ownerID), displayName: displayName ?? "you")
        let summaries = stubs.map { stub in
            ConversationSummary(
                id: ConversationID(stub.threadID.rawValue),
                title: InstagramWebFormat.title(for: stub, ownerID: ownerID),
                sentByOwner: 0,
                receivedFromOthers: 0,
                firstSentAt: nil,
                lastSentAt: nil,
                messagesLoaded: false
            )
        }
        return try library.mergeListing(account: account, stubs: summaries)
    }

    public func load(
        session: InstagramWebSession,
        ids: [ConversationID],
        onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil
    ) async throws -> LibraryOverview {
        let ownerID = session.userID
        let wanted = try await library.conversations().filter { ids.contains($0.id) }
        let total = wanted.count
        var sends = 0
        var overview = LibraryOverview(conversations: try await library.conversations())
        for (index, listed) in wanted.enumerated() {
            try Task.checkCancellation()
            let sendsSoFar = sends
            let conversation = try await loadConversation(id: listed.id.rawValue, title: listed.title, ownerID: ownerID) { partial in
                onProgress?(InboxReadProgress(
                    chatsFound: total,
                    chatsRead: index,
                    chatsTotal: total,
                    sendsFound: sendsSoFar + partial,
                    currentTitle: listed.title
                ))
            }
            overview = try library.upsertLoaded(summary: conversation.summary, messages: conversation.messages)
            sends += conversation.messages.count
            onProgress?(InboxReadProgress(
                chatsFound: total,
                chatsRead: index + 1,
                chatsTotal: total,
                sendsFound: sends,
                currentTitle: listed.title
            ))
            if listingDelay > 0 { try await clock.sleep(for: listingDelay) }
        }
        return overview
    }

    private func fetchInbox(cursor: String?) async throws -> InstagramWebFormat.InboxPage {
        var query = [
            "persistentBadging": "true",
            "folder": "inbox",
            "limit": String(pageSize),
            "thread_message_limit": "0",
            "visual_message_return_type": "unseen"
        ]
        if let cursor { query["cursor"] = cursor }
        let response = try await client.send(InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/inbox/", query: query))
        do {
            return try InstagramWebFormat.parseInbox(response.body)
        } catch {
            throw IntegrationError.unexpectedResponse(code: response.statusCode)
        }
    }

    private struct LoadedConversation {
        var summary: ConversationSummary
        var messages: [DiscoveredMessage]
    }

    private func loadConversation(
        id: String,
        title: String,
        ownerID: String,
        onPartial: (@Sendable (Int) -> Void)? = nil
    ) async throws -> LoadedConversation {
        let conversationID = ConversationID(id)
        var ownerMessages: [DiscoveredMessage] = []
        var received = 0
        var cursor: String?
        var hasOlder = true
        var seen = Set<String>()

        while hasOlder {
            try Task.checkCancellation()
            let page = try await fetchThread(id: id, cursor: cursor)
            let items = page.thread?.items ?? []
            for item in items {
                guard !item.isSystem, !item.itemID.isEmpty else { continue }
                guard seen.insert(item.itemID).inserted else { continue }
                let authoredByOwner: Bool
                if let sentByViewer = item.sentByViewer {
                    authoredByOwner = sentByViewer
                } else if let authorID = item.authorID {
                    authoredByOwner = authorID == ownerID
                } else {
                    continue
                }
                if authoredByOwner {
                    ownerMessages.append(DiscoveredMessage(
                        ref: MessageRef(conversationID: conversationID, messageID: item.itemID),
                        authorID: ParticipantID("ig:" + ownerID),
                        sentAt: item.sentAt,
                        kind: item.kind
                    ))
                } else {
                    received += 1
                }
            }
            hasOlder = page.thread?.hasOlder ?? false
            cursor = page.thread?.oldestCursor
            if cursor == nil { hasOlder = false }
            onPartial?(ownerMessages.count)
            if hasOlder, listingDelay > 0 { try await clock.sleep(for: listingDelay) }
        }

        ownerMessages.sort { ($0.sentAt, $0.ref.messageID) < ($1.sentAt, $1.ref.messageID) }
        var byKind: [MessageKind: Int] = [:]
        for message in ownerMessages { byKind[message.kind, default: 0] += 1 }

        let summary = ConversationSummary(
            id: conversationID,
            title: title,
            sentByOwner: ownerMessages.count,
            receivedFromOthers: received,
            firstSentAt: ownerMessages.first?.sentAt,
            lastSentAt: ownerMessages.last?.sentAt,
            sentByKind: byKind,
            messagesLoaded: true
        )
        return LoadedConversation(summary: summary, messages: ownerMessages)
    }

    private func fetchThread(id: String, cursor: String?) async throws -> InstagramWebFormat.ThreadPage {
        var query = ["limit": String(pageSize)]
        if let cursor {
            query["cursor"] = cursor
            query["direction"] = "older"
        }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response = try await client.send(
            InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/threads/\(encoded)/", query: query)
        )
        do {
            return try InstagramWebFormat.parseThread(response.body)
        } catch {
            throw IntegrationError.unexpectedResponse(code: response.statusCode)
        }
    }
}
