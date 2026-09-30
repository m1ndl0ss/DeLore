import Foundation

/// Unsends via Instagram's website session — the same Unsend action the user can perform
/// in Instagram's own web inbox.
///
/// Order that works today:
/// 1. GraphQL `direct_unsend_message` on www.instagram.com (`mid.$…` + real `fb_dtsg`).
///    Relay-only headers; do not send Instagram mobile-API extras or `__a=1`.
/// 2. Empty-body POST to `i.instagram.com/.../items/{id}/delete/` (www has no such route;
///    a form body with `_uid` returns 4415001).
/// Desktop Chrome UA only. Does not retry a single failing request.
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
        guard let owner = try ownerID(), !owner.isEmpty else { throw IntegrationError.sessionExpired }
        var last: IntegrationError?
        if let mid = try? await webMessageID(of: target), let mid, !mid.isEmpty {
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
        for request in restUnsendAttempts(target, owner: owner) {
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
        throw last ?? IntegrationError.unavailable
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        guard try isOwned(target) else { return .notOwned }
        var cursor: String?
        for _ in 0..<presencePageLimit {
            let page = try await fetchInstagramThread(client: client, id: target.ref.conversationID.rawValue, cursor: cursor)
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

    private func restUnsendAttempts(_ target: CleanupTarget, owner _: String) -> [InstagramAPIRequest] {
        return [
            InstagramAPIRequest(
                method: .post,
                path: deletePath(target.ref),
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

    private func webMessageID(of target: CleanupTarget) async throws -> String? {
        var cursor: String?
        for _ in 0..<presencePageLimit {
            let page = try await fetchInstagramThread(client: client, id: target.ref.conversationID.rawValue, cursor: cursor)
            if let item = page.thread?.items?.first(where: { $0.itemID == target.ref.messageID }) {
                return item.webMessageID
            }
            guard page.thread?.hasOlder == true, let next = page.thread?.oldestCursor else {
                return nil
            }
            cursor = next
        }
        return nil
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
