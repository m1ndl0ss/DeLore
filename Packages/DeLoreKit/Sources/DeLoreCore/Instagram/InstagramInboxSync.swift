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
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> LibraryOverview {
        let ownerID = session.userID
        var displayName = session.displayName
        var stubs: [InstagramWebFormat.InboxPage.ThreadStub] = []
        var cursor: String?
        var inboxHasOlder = true

        while inboxHasOlder {
            try Task.checkCancellation()
            let page = try await fetchInbox(cursor: cursor)
            if displayName == nil, let username = page.viewer?.username, !username.isEmpty {
                displayName = username
            }
            stubs.append(contentsOf: page.inbox?.threads ?? [])
            inboxHasOlder = page.inbox?.hasOlder ?? false
            cursor = page.inbox?.oldestCursor
            if cursor == nil { inboxHasOlder = false }
            if listingDelay > 0 { try await clock.sleep(for: listingDelay) }
        }

        let account = AccountIdentity(ownerID: ParticipantID("ig:" + ownerID), displayName: displayName ?? "you")
        let writer = try library.beginImport(account: account)
        let total = max(stubs.count, 1)

        for (index, stub) in stubs.enumerated() {
            try Task.checkCancellation()
            let conversation = try await loadConversation(stub: stub, ownerID: ownerID)
            try writer.add(summary: conversation.summary, messages: conversation.messages)
            onProgress?(Double(index + 1) / Double(total))
            if listingDelay > 0 { try await clock.sleep(for: listingDelay) }
        }

        return try writer.commit()
    }

    private func fetchInbox(cursor: String?) async throws -> InstagramWebFormat.InboxPage {
        var query = [
            "persistentBadging": "true",
            "folder": "inbox",
            "limit": String(pageSize),
            "thread_message_limit": "1"
        ]
        if let cursor { query["cursor"] = cursor }
        let response = try await client.send(InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/inbox/", query: query))
        do {
            return try JSONDecoder().decode(InstagramWebFormat.InboxPage.self, from: response.body)
        } catch {
            throw IntegrationError.unexpectedResponse(code: response.statusCode)
        }
    }

    private struct LoadedConversation {
        var summary: ConversationSummary
        var messages: [DiscoveredMessage]
    }

    private func loadConversation(
        stub: InstagramWebFormat.InboxPage.ThreadStub,
        ownerID: String
    ) async throws -> LoadedConversation {
        let conversationID = ConversationID(stub.threadID.rawValue)
        var ownerMessages: [DiscoveredMessage] = []
        var received = 0
        var cursor: String?
        var hasOlder = true
        var seen = Set<String>()

        while hasOlder {
            try Task.checkCancellation()
            let page = try await fetchThread(id: stub.threadID.rawValue, cursor: cursor)
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
            if hasOlder, listingDelay > 0 { try await clock.sleep(for: listingDelay) }
        }

        ownerMessages.sort { ($0.sentAt, $0.ref.messageID) < ($1.sentAt, $1.ref.messageID) }
        var byKind: [MessageKind: Int] = [:]
        for message in ownerMessages { byKind[message.kind, default: 0] += 1 }

        let summary = ConversationSummary(
            id: conversationID,
            title: InstagramWebFormat.title(for: stub, ownerID: ownerID),
            sentByOwner: ownerMessages.count,
            receivedFromOthers: received,
            firstSentAt: ownerMessages.first?.sentAt,
            lastSentAt: ownerMessages.last?.sentAt,
            sentByKind: byKind
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
            return try JSONDecoder().decode(InstagramWebFormat.ThreadPage.self, from: response.body)
        } catch {
            throw IntegrationError.unexpectedResponse(code: response.statusCode)
        }
    }
}
