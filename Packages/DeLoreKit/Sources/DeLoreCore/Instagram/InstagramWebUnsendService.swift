import Foundation

/// Unsends via Instagram's website session — GraphQL `direct_unsend_message` with a `mid.$…` id.
/// Numeric REST delete returns 1404006 on the web session and is not used.
///
/// Resolve walks the live thread for `mid.$…` when the library only has numeric `item_id`.
/// Instagram pages from the absolute tip (often hundreds of the other person's newer messages),
/// so resolve resumes a per-thread cursor instead of re-reading the tip every time.
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
        resolvePageSize: Int = 100
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
        let stored = target.ref.messageID
        let thread = target.ref.conversationID.rawValue

        let mid: String?
        if stored.hasPrefix("mid.") {
            mid = stored
        } else {
            mid = try await resolveIds(target)?.mid
        }

        guard let mid, !mid.isEmpty else {
            if await midCache.consumeGone(thread: thread, stored: stored) {
                return .alreadyGone
            }
            throw IntegrationError.unavailable
        }

        let response = try await client.send(graphqlUnsend(target, owner: owner, messageID: mid))
        let outcome = try InstagramDeleteParse.outcome(from: response)
        await midCache.forget(thread: thread, stored: stored, mid: mid)
        await midCache.invalidatePages(thread: thread)
        return outcome
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        guard try isOwned(target) else { return .notOwned }
        let thread = target.ref.conversationID.rawValue
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

    private func matches(_ stored: String, item: InstagramWebFormat.Item) -> Bool {
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

        // Resume deepest cursor. Only restart tip when that page sits *below* the target
        // (true overshoot) — not when global oldest-of-all-speakers is ancient.
        var cursor = await midCache.scanCursor(thread: thread)
        var allowedTipRestart = cursor != nil
        var pages = 0
        var networkPages = 0
        while pages < resolvePageLimit {
            let pageStart = cursor
            let (page, fromCache) = try await midCache.fetchPage(
                thread: thread,
                cursor: cursor,
                pageSize: resolvePageSize
            ) {
                try await fetchInstagramThread(
                    client: client,
                    id: thread,
                    cursor: cursor,
                    limit: resolvePageSize
                )
            }
            let items = page.thread?.items ?? []
            pages += 1
            if !fromCache { networkPages += 1 }

            var pageOldest: Date?
            var pageNewest: Date?
            for item in items {
                if pageOldest == nil || item.sentAt < pageOldest! { pageOldest = item.sentAt }
                if pageNewest == nil || item.sentAt > pageNewest! { pageNewest = item.sentAt }
                if let mid = item.webMessageID, mid.hasPrefix("mid.") {
                    await midCache.remember(thread: thread, itemID: item.itemID, mid: mid)
                }
            }

            if allowedTipRestart,
               pageStart != nil,
               let pageNewest,
               target.sentAt > pageNewest.addingTimeInterval(5) {
                cursor = nil
                await midCache.setScanCursor(thread: thread, cursor: nil)
                allowedTipRestart = false
                continue
            }
            allowedTipRestart = false

            for item in items {
                guard matches(stored, item: item) else { continue }
                if let mid = item.webMessageID, mid.hasPrefix("mid.") {
                    await midCache.setScanCursor(thread: thread, cursor: pageStart)
                    return (mid, item.itemID)
                }
                // Live item without mid.$ — retry later; do not stamp as permanently gone.
                return nil
            }

            guard page.thread?.hasOlder == true, let next = page.thread?.oldestCursor else {
                await midCache.setScanCursor(thread: thread, cursor: nil)
                await midCache.markGone(thread: thread, stored: stored)
                break
            }
            if let pageOldest, pageOldest < target.sentAt.addingTimeInterval(-1) {
                await midCache.setScanCursor(thread: thread, cursor: pageStart)
                await midCache.markGone(thread: thread, stored: stored)
                break
            }
            cursor = next
            await midCache.setScanCursor(thread: thread, cursor: cursor)
            if !fromCache, pages < resolvePageLimit {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return nil
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

    /// Free cached thread pages after a job ends (mid map kept for a later resume).
    public func releaseWorkingCaches() async {
        await midCache.releaseWorkingCaches()
    }
}

private actor MidCache {
    private var midByItem: [String: String] = [:]
    private var itemByMid: [String: String] = [:]
    private var scanCursorByThread: [String: String?] = [:]
    private var gone: Set<String> = []
    private var pageCache: [String: InstagramWebFormat.ThreadPage] = [:]
    private var pageCacheOrder: [String] = []

    func remember(thread: String, itemID: String, mid: String) {
        midByItem["\(thread)|\(itemID)"] = mid
        itemByMid["\(thread)|\(mid)"] = itemID
    }

    func remember(thread: String, item: InstagramWebFormat.Item) {
        guard let mid = item.webMessageID, mid.hasPrefix("mid.") else { return }
        remember(thread: thread, itemID: item.itemID, mid: mid)
    }

    func forget(thread: String, stored: String, mid: String) {
        midByItem.removeValue(forKey: "\(thread)|\(stored)")
        midByItem.removeValue(forKey: "\(thread)|\(mid)")
        itemByMid.removeValue(forKey: "\(thread)|\(mid)")
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

    func scanCursor(thread: String) -> String? {
        scanCursorByThread[thread] ?? nil
    }

    func setScanCursor(thread: String, cursor: String?) {
        scanCursorByThread[thread] = cursor
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

    func fetchPage(
        thread: String,
        cursor: String?,
        pageSize: Int,
        load: () async throws -> InstagramWebFormat.ThreadPage
    ) async throws -> (InstagramWebFormat.ThreadPage, Bool) {
        let key = "\(thread)|\(cursor ?? "")|\(pageSize)"
        if let cached = pageCache[key] {
            return (cached, true)
        }
        let page = try await load()
        pageCache[key] = page
        pageCacheOrder.append(key)
        while pageCacheOrder.count > 24 {
            let old = pageCacheOrder.removeFirst()
            pageCache.removeValue(forKey: old)
        }
        return (page, false)
    }

    func invalidatePages(thread: String) {
        let prefix = "\(thread)|"
        let stale = pageCacheOrder.filter { $0.hasPrefix(prefix) }
        for key in stale {
            pageCache.removeValue(forKey: key)
            pageCacheOrder.removeAll { $0 == key }
        }
    }

    func releaseWorkingCaches() {
        pageCache.removeAll(keepingCapacity: false)
        pageCacheOrder.removeAll(keepingCapacity: false)
    }
}
