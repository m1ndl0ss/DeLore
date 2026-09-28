import Foundation

/// Unsends via Instagram's website session — the same Unsend action the user can perform
/// in Instagram's own web inbox. Never retries internally.
public struct InstagramWebUnsendService: UnsendService {
    private let client: InstagramAPIClient
    private let ownerID: @Sendable () throws -> String?
    private let presencePageLimit: Int

    public init(
        client: InstagramAPIClient,
        ownerID: @escaping @Sendable () throws -> String?,
        presencePageLimit: Int = 8
    ) {
        self.client = client
        self.ownerID = ownerID
        self.presencePageLimit = max(1, presencePageLimit)
    }

    public func unsend(_ target: CleanupTarget) async throws -> UnsendOutcome {
        guard try isOwned(target) else { return .notOwned }
        let response = try await client.send(InstagramAPIRequest(
            method: .post,
            path: deletePath(target.ref),
            isIdempotent: false,
            destructive: true
        ))
        return InstagramDeleteParse.outcome(from: response)
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        guard try isOwned(target) else { return .notOwned }
        var cursor: String?
        for _ in 0..<presencePageLimit {
            let page = try await fetchThread(id: target.ref.conversationID.rawValue, cursor: cursor)
            let items = page.thread?.items ?? []
            if let item = items.first(where: { $0.itemID == target.ref.messageID }) {
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
        return .gone
    }

    private func isOwned(_ target: CleanupTarget) throws -> Bool {
        guard let owner = try ownerID(), !owner.isEmpty else { throw IntegrationError.sessionExpired }
        return target.authorID == ParticipantID("ig:" + owner)
    }

    private func deletePath(_ ref: MessageRef) -> String {
        let thread = encode(ref.conversationID.rawValue)
        let item = encode(ref.messageID)
        return "/api/v1/direct_v2/threads/\(thread)/items/\(item)/delete/"
    }

    private func fetchThread(id: String, cursor: String?) async throws -> InstagramWebFormat.ThreadPage {
        var query = ["limit": "20"]
        if let cursor {
            query["cursor"] = cursor
            query["direction"] = "older"
        }
        let response = try await client.send(
            InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/threads/\(encode(id))/", query: query)
        )
        return try JSONDecoder().decode(InstagramWebFormat.ThreadPage.self, from: response.body)
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
