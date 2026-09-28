import DeLoreCore
import Foundation

/// Scriptable Instagram website stand-in. Serves inbox/thread JSON and records deletes
/// without any network. Used so the live integration can be tested in CI.
public final class FakeInstagramAPIClient: InstagramAPIClient, @unchecked Sendable {
    public struct Item: Sendable {
        public var id: String
        public var userID: String
        public var timestampMicros: Int64
        public var type: String
        public var sentByViewer: Bool?

        public init(id: String, userID: String, timestampMicros: Int64, type: String = "text", sentByViewer: Bool? = nil) {
            self.id = id
            self.userID = userID
            self.timestampMicros = timestampMicros
            self.type = type
            self.sentByViewer = sentByViewer
        }
    }

    public struct Thread: Sendable {
        public var id: String
        public var title: String
        public var users: [(pk: String, username: String)]
        public var items: [Item]

        public init(id: String, title: String, users: [(pk: String, username: String)], items: [Item]) {
            self.id = id
            self.title = title
            self.users = users
            self.items = items
        }
    }

    public enum Fault: Sendable, Equatable {
        case rateLimited
        case sessionExpired
        case verificationRequired
        case serverError
        case timeout
        case alreadyGone
        case malformed
    }

    public let ownerID: String
    public let username: String
    private let lock = NSLock()
    private var threads: [Thread]
    private var scripted: [Int: Fault] = [:]
    private var persistent: Fault?
    private var callCount = 0
    private(set) public var deleteCalls = 0
    private(set) public var deletedIDs: [String] = []
    public var inboxPageSize = 20
    public var threadPageSize = 20

    public init(ownerID: String = "42", username: String = "you", threads: [Thread]) {
        self.ownerID = ownerID
        self.username = username
        self.threads = threads
    }

    public func script(_ fault: Fault, onCall call: Int) {
        lock.withLock { scripted[call] = fault }
    }

    public func setPersistent(_ fault: Fault?) {
        lock.withLock { persistent = fault }
    }

    public func remaining(in threadID: String) -> [Item] {
        lock.withLock { threads.first { $0.id == threadID }?.items ?? [] }
    }

    public func send(_ request: InstagramAPIRequest) async throws -> HTTPResponse {
        let call = lock.withLock { () -> Int in
            callCount += 1
            return callCount
        }
        if let fault = lock.withLock({ scripted[call] ?? persistent }) {
            let response = try apply(fault, request: request)
            try InstagramResponseClassifier.throwIfNeeded(response, destructive: request.destructive)
            return response
        }
        let response: HTTPResponse
        if request.path.contains("/delete/") {
            response = try delete(request)
        } else if request.path.contains("/inbox/") {
            response = inbox(request)
        } else if request.path.contains("/threads/") {
            response = thread(request)
        } else {
            response = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        try InstagramResponseClassifier.throwIfNeeded(response, destructive: request.destructive)
        return response
    }

    private func apply(_ fault: Fault, request: InstagramAPIRequest) throws -> HTTPResponse {
        switch fault {
        case .rateLimited:
            return json(429, ["message": "feedback_required", "spam": true, "status": "fail"])
        case .sessionExpired:
            return json(401, ["message": "login_required", "status": "fail"])
        case .verificationRequired:
            return json(403, ["checkpoint_required": true, "status": "fail"])
        case .serverError:
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        case .timeout:
            throw IntegrationError.transportFailure(requestMayHaveBeenApplied: request.destructive)
        case .alreadyGone:
            return json(200, ["message": "Item not found", "status": "fail"])
        case .malformed:
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>oops</html>".utf8))
        }
    }

    private func delete(_ request: InstagramAPIRequest) throws -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard let threadIndex = parts.firstIndex(of: "threads"),
              parts.count > threadIndex + 3 else {
            return json(404, ["status": "fail"])
        }
        let threadID = parts[threadIndex + 1]
        let itemID = parts[threadIndex + 3]
        return lock.withLock {
            deleteCalls += 1
            guard let tIndex = threads.firstIndex(where: { $0.id == threadID }) else {
                return json(200, ["message": "Item not found", "status": "fail"])
            }
            guard let iIndex = threads[tIndex].items.firstIndex(where: { $0.id == itemID }) else {
                return json(200, ["message": "Item not found", "status": "fail"])
            }
            let item = threads[tIndex].items[iIndex]
            if item.userID != ownerID {
                return json(200, ["status": "ok"])
            }
            threads[tIndex].items.remove(at: iIndex)
            deletedIDs.append(itemID)
            return json(200, ["status": "ok"])
        }
    }

    private func inbox(_ request: InstagramAPIRequest) -> HTTPResponse {
        lock.withLock {
            let cursor = request.query["cursor"]
            let start = cursor.flatMap { value in threads.firstIndex(where: { $0.id == value }).map { $0 + 1 } } ?? 0
            let end = min(threads.count, start + inboxPageSize)
            let slice = start < threads.count ? Array(threads[start..<end]) : []
            let hasOlder = end < threads.count
            let payload: [String: Any] = [
                "viewer": ["pk": ownerID, "username": username],
                "inbox": [
                    "threads": slice.map { stubJSON($0, includeItems: false) },
                    "has_older": hasOlder,
                    "oldest_cursor": hasOlder ? slice.last?.id ?? "" : ""
                ],
                "status": "ok"
            ]
            return json(200, payload)
        }
    }

    private func thread(_ request: InstagramAPIRequest) -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard let threadIndex = parts.firstIndex(of: "threads"),
              parts.count > threadIndex + 1 else {
            return json(404, ["status": "fail"])
        }
        let threadID = parts[threadIndex + 1]
        return lock.withLock {
            guard let thread = threads.first(where: { $0.id == threadID }) else {
                return json(404, ["message": "not found", "status": "fail"])
            }
            let newestFirst = Array(thread.items.reversed())
            let cursor = request.query["cursor"]
            let start: Int
            if let cursor, let index = newestFirst.firstIndex(where: { $0.id == cursor }) {
                start = newestFirst.index(after: index)
            } else {
                start = 0
            }
            let end = min(newestFirst.count, start + threadPageSize)
            let page = start < newestFirst.count ? Array(newestFirst[start..<end]) : []
            let hasOlder = end < newestFirst.count
            let payload: [String: Any] = [
                "thread": [
                    "thread_id": thread.id,
                    "thread_title": thread.title,
                    "users": thread.users.map { ["pk": $0.pk, "username": $0.username] },
                    "items": page.map(itemJSON),
                    "has_older": hasOlder,
                    "oldest_cursor": page.last?.id ?? ""
                ],
                "status": "ok"
            ]
            return json(200, payload)
        }
    }

    private func stubJSON(_ thread: Thread, includeItems: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "thread_id": thread.id,
            "thread_title": thread.title,
            "users": thread.users.map { ["pk": $0.pk, "username": $0.username] },
            "has_older": true
        ]
        if includeItems {
            json["items"] = thread.items.suffix(1).map(itemJSON)
        }
        return json
    }

    private func itemJSON(_ item: Item) -> [String: Any] {
        var json: [String: Any] = [
            "item_id": item.id,
            "user_id": item.userID,
            "timestamp": item.timestampMicros,
            "item_type": item.type,
            "text": "SECRET-SHOULD-NEVER-BE-STORED"
        ]
        if let sentByViewer = item.sentByViewer { json["is_sent_by_viewer"] = sentByViewer }
        return json
    }

    private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
    }
}

public extension FakeInstagramAPIClient {
    static func sampleInbox(ownerID: String = "42") -> FakeInstagramAPIClient {
        let now: Int64 = 1_700_000_000_000_000
        return FakeInstagramAPIClient(ownerID: ownerID, username: "you", threads: [
            Thread(id: "t1", title: "bestie", users: [(ownerID, "you"), ("7", "bestie")], items: [
                Item(id: "m1", userID: ownerID, timestampMicros: now, type: "text"),
                Item(id: "m2", userID: "7", timestampMicros: now + 1, type: "text"),
                Item(id: "m3", userID: ownerID, timestampMicros: now + 2, type: "media"),
                Item(id: "m4", userID: ownerID, timestampMicros: now + 3, type: "voice_media")
            ]),
            Thread(id: "t2", title: "the group", users: [(ownerID, "you"), ("8", "sam"), ("9", "jo")], items: [
                Item(id: "g1", userID: "8", timestampMicros: now, type: "text"),
                Item(id: "g2", userID: ownerID, timestampMicros: now + 5, type: "link"),
                Item(id: "g3", userID: ownerID, timestampMicros: now + 6, type: "action_log")
            ])
        ])
    }
}
