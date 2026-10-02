import Foundation

/// Unsends via Instagram's website session — the same Unsend action the user can perform
/// in Instagram's own web inbox.
///
/// Order that works today:
/// 1. GraphQL `direct_unsend_message` on www with a `mid.$…` id (stored, or resolved from the thread).
/// 2. Empty-body POST to `i.instagram.com/.../items/{numeric_id}/delete/` only if GraphQL had a mid
///    and still failed. Numeric-only REST returns 1404006 on the web session and (on Android)
///    parks the WebView on i.instagram.com, breaking later GraphQL calls.
///
/// Resolve walks the live thread for `mid.$…` when the library only has numeric `item_id`.
/// Instagram pages from the absolute tip, which can be hundreds of the other person's messages
/// after your last send — so resolve resumes a per-thread cursor instead of re-reading the tip.
public struct InstagramWebUnsendService: UnsendService {
    private let client: InstagramAPIClient
    private let ownerID: @Sendable () throws -> String?
    private let presencePageLimit: Int
    private let resolvePageLimit: Int
    private let resolvePageSize: Int
    private let midCache = MidCache()

    public init(
        client: InstagramAPIClient,
        ownerID: @escaping @Sendable () throws -> String?,
        presencePageLimit: Int = 8,
        resolvePageLimit: Int = 200,
        resolvePageSize: Int = 50
    ) {
        self.client = client
        self.ownerID = ownerID
        self.presencePageLimit = max(1, presencePageLimit)
        self.resolvePageLimit = max(1, resolvePageLimit)
        self.resolvePageSize = max(1, resolvePageSize)
    }

    public func unsend(_ target: CleanupTarget) async throws -> UnsendOutcome {
        guard try isOwned(target) else { return .notOwned }
        guard let owner = try ownerID(), !owner.isEmpty else { throw IntegrationError.sessionExpired }
        var last: IntegrationError?
        let stored = target.ref.messageID
        let thread = target.ref.conversationID.rawValue

        let resolved: (mid: String, itemID: String)?
        if stored.hasPrefix("mid.") {
            if let item = await midCache.itemID(thread: thread, mid: stored) {
                resolved = (stored, item)
            } else {
                resolved = (stored, stored)
            }
        } else {
            resolved = try await resolveIds(target)
        }

        if resolved == nil, !stored.hasPrefix("mid."),
           await midCache.consumeGone(thread: thread, stored: stored) {
            return .alreadyGone
        }

        if let mid = resolved?.mid, !mid.isEmpty {
            do {
                let response = try await client.send(graphqlUnsend(target, owner: owner, messageID: mid))
                return try InstagramDeleteParse.outcome(from: response)
            } catch let error as IntegrationError {
                switch error {
                case .unexpectedResponse, .transportFailure:
                    last = error
                default:
                    throw error
                }
            }
        }

        // REST only after GraphQL had a mid and failed — never for numeric-only library ids.
        if let mid = resolved?.mid, mid.hasPrefix("mid."),
           let restID = resolved?.itemID, !restID.hasPrefix("mid.") {
            for request in restUnsendAttempts(target, itemID: restID) {
                do {
                    let response = try await client.send(request)
                    return try InstagramDeleteParse.outcome(from: response)
                } catch let error as IntegrationError {
                    switch error {
                    case .unexpectedResponse, .transportFailure:
                        last = error
                    default:
                        throw error
                    }
                }
            }
        }
        throw last ?? IntegrationError.unavailable
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        guard try isOwned(target) else { return .notOwned }
        let thread = target.ref.conversationID.rawValue
        if await midCache.has(thread: thread, stored: target.ref.messageID) {
            return .present
        }
        var cursor: String?
        for _ in 0..<presencePageLimit {
            let page = try await fetchInstagramThread(client: client, id: thread, cursor: cursor)
            let items = page.thread?.items ?? []
            if let item = items.first(where: { matches(target.ref.messageID, item: $0) }) {
                await midCache.remember(thread: thread, item: item)
                if item.isSystem { return .gone }
                if let viewer = item.sentByViewer, !viewer { return .notOwned }
                if let author = item.authorID, let owner = try ownerID(), author != owner { return .notOwned }
                return .present
            }
            let oldest = items.map(\.sentAt).min()
            if let oldest, oldest < target.sentAt.addingTimeInterval(-1) {
                return .gone
            }
            guard page.thread?.hasOlder == true, let next = page.thread?.oldestCursor else {
                return .gone
            }
            cursor = next
        }
        return .present
    }

    private func isOwned(_ target: CleanupTarget) throws -> Bool {
        guard let owner = try ownerID(), !owner.isEmpty else { throw IntegrationError.sessionExpired }
        return target.authorID == ParticipantID("ig:" + owner)
    }

    private func matches(_ stored: String, item: InstagramWebFormat.Thread.Item) -> Bool {
        item.itemID == stored || item.webMessageID == stored
    }

    private func resolveIds(_ target: CleanupTarget) async throws -> (mid: String, itemID: String)? {
        let thread = target.ref.conversationID.rawValue
        let stored = target.ref.messageID
        if await midCache.isGone(thread: thread, stored: stored) {
            return nil
        }
        if let cached = await midCache.lookup(thread: thread, stored: stored) {
            return cached
        }
        var cursor = await midCache.scanCursor(thread: thread)
        if let oldest = await midCache.oldest(thread: thread),
           target.sentAt > oldest.addingTimeInterval(5) {
            cursor = nil
        }
        var pages = 0
        var midHits = 0
        while pages < resolvePageLimit {
            let page = try await fetchInstagramThread(
                client: client,
                id: thread,
                cursor: cursor,
                limit: resolvePageSize
            )
            let items = page.thread?.items ?? []
            pages += 1
            var pageOldest: Date?
            for item in items {
                if pageOldest == nil || item.sentAt < pageOldest! {
                    pageOldest = item.sentAt
                }
                if let mid = item.webMessageID, mid.hasPrefix("mid.") {
                    midHits += 1
                    await midCache.remember(thread: thread, itemID: item.itemID, mid: mid)
                }
                guard matches(stored, item: item) else { continue }
                if let mid = item.webMessageID, mid.hasPrefix("mid.") {
                    return (mid, item.itemID)
                }
                return nil
            }
            if let pageOldest {
                await midCache.noteOldest(thread: thread, date: pageOldest)
            }
            guard page.thread?.hasOlder == true, let next = page.thread?.oldestCursor else {
                await midCache.setScanCursor(thread: thread, cursor: nil)
                await midCache.markGone(thread: thread, stored: stored)
                break
            }
            cursor = next
            await midCache.setScanCursor(thread: thread, cursor: cursor)
            if let pageOldest, pageOldest < target.sentAt.addingTimeInterval(-1) {
                await midCache.markGone(thread: thread, stored: stored)
                break
            }
        }
        _ = midHits
        return nil
    }

    private func deletePath(thread: String, item: String) -> String {
        "/api/v1/direct_v2/threads/\(encode(thread))/items/\(encode(item))/delete/"
    }

    private func restUnsendAttempts(_ target: CleanupTarget, itemID: String) -> [InstagramAPIRequest] {
        [
            InstagramAPIRequest(
                method: .post,
                path: deletePath(thread: target.ref.conversationID.rawValue, item: itemID),
                body: Sensitive(Data()),
                host: InstagramWebConstants.apiHost,
                isIdempotent: false,
                destructive: true
            ),
        ]
    }

    private func graphqlUnsend(_ target: CleanupTarget, owner: String, messageID: String) -> InstagramAPIRequest {
        let variablesObject: [String: Any] = [
            "message_id": messageID,
            "send_data": ["thread_id": target.ref.conversationID.rawValue],
        ]
        let variables = (try? JSONSerialization.data(withJSONObject: variablesObject)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{\"message_id\":\"\(messageID)\",\"send_data\":{\"thread_id\":\"\(target.ref.conversationID.rawValue)\"}}"
        return InstagramAPIRequest(
            method: .post,
            path: "/api/graphql",
            form: [
                "av": owner,
                "__user": owner,
                "fb_api_caller_class": "RelayModern",
                "fb_api_req_friendly_name": "direct_unsend_message",
                "variables": variables,
                "server_timestamps": "true",
                "doc_id": InstagramWebConstants.unsendDocID,
            ],
            host: InstagramWebConstants.wwwHost,
            isIdempotent: false,
            destructive: true
        )
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private actor MidCache {
    private var midByItem: [String: String] = [:]
    private var itemByMid: [String: String] = [:]
    private var scanCursorByThread: [String: String?] = [:]
    private var oldestByThread: [String: Date] = [:]
    private var gone: Set<String> = []

    func remember(thread: String, itemID: String, mid: String) {
        midByItem["\(thread)|\(itemID)"] = mid
        itemByMid["\(thread)|\(mid)"] = itemID
    }

    func remember(thread: String, item: InstagramWebFormat.Thread.Item) {
        guard let mid = item.webMessageID, mid.hasPrefix("mid.") else { return }
        remember(thread: thread, itemID: item.itemID, mid: mid)
    }

    func lookup(thread: String, stored: String) -> (mid: String, itemID: String)? {
        if stored.hasPrefix("mid."), let item = itemByMid["\(thread)|\(stored)"] {
            return (stored, item)
        }
        if let mid = midByItem["\(thread)|\(stored)"] {
            return (mid, stored)
        }
        return nil
    }

    func itemID(thread: String, mid: String) -> String? {
        itemByMid["\(thread)|\(mid)"]
    }

    func has(thread: String, stored: String) -> Bool {
        lookup(thread: thread, stored: stored) != nil
    }

    func scanCursor(thread: String) -> String? {
        scanCursorByThread[thread] ?? nil
    }

    func setScanCursor(thread: String, cursor: String?) {
        scanCursorByThread[thread] = cursor
    }

    func oldest(thread: String) -> Date? {
        oldestByThread[thread]
    }

    func noteOldest(thread: String, date: Date) {
        if let prior = oldestByThread[thread] {
            oldestByThread[thread] = min(prior, date)
        } else {
            oldestByThread[thread] = date
        }
    }

    func markGone(thread: String, stored: String) {
        gone.insert("\(thread)|\(stored)")
    }

    func isGone(thread: String, stored: String) -> Bool {
        gone.contains("\(thread)|\(stored)")
    }

    func consumeGone(thread: String, stored: String) -> Bool {
        gone.remove("\(thread)|\(stored)") != nil
    }
}
