@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

final class InstagramWebIntegrationTests: XCTestCase {
    func testInboxSyncKeepsOnlyOwnerMessagesAndDropsContent() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibraryStore(root: directory)
        let session = Self.session(userID: fake.ownerID)
        let overview = try await InstagramInboxSync(client: fake, library: library, listingDelay: 0, clock: ManualClock())
            .run(session: session)

        XCTAssertEqual(overview.sentByOwner, 4, "3 texts/media/voice in chat 1 + 1 link in chat 2; action_log skipped")
        XCTAssertEqual(overview.receivedFromOthers, 2)
        let bestie = try XCTUnwrap(overview.conversations.first { $0.id.rawValue == "t1" })
        XCTAssertEqual(bestie.sentByOwner, 3)
        XCTAssertEqual(bestie.receivedFromOthers, 1)
        XCTAssertEqual(bestie.sentByKind[.media], 1)
        XCTAssertEqual(bestie.sentByKind[.voice], 1)

        var ids: [String] = []
        for try await page in library.messagePages(in: bestie.id, pageSize: 10) {
            XCTAssertTrue(page.allSatisfy { $0.authorID == session.ownerID })
            ids += page.map(\.ref.messageID)
        }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["m1", "m3", "m4"])

        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { continue }
            XCTAssertFalse(text.contains("SECRET-SHOULD-NEVER-BE-STORED"), "message text leaked into \(url.lastPathComponent)")
        }
    }

    func testInboxListDoesNotLoadMessageHistory() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibraryStore(root: directory)
        let session = Self.session(userID: fake.ownerID)
        let listed = try await InstagramInboxSync(client: fake, library: library, listingDelay: 0, clock: ManualClock())
            .list(session: session)

        XCTAssertEqual(listed.conversations.count, 2)
        XCTAssertEqual(listed.sentByOwner, 0)
        XCTAssertEqual(listed.unreadConversations.count, 2)
        XCTAssertTrue(listed.conversations.allSatisfy { !$0.messagesLoaded })
        XCTAssertEqual(listed.conversations.first { $0.id.rawValue == "t1" }?.title, "@bestie")

        let loaded = try await InstagramInboxSync(client: fake, library: library, listingDelay: 0, clock: ManualClock())
            .load(session: session, ids: [ConversationID("t1")])
        let bestie = try XCTUnwrap(loaded.conversations.first { $0.id.rawValue == "t1" })
        XCTAssertTrue(bestie.messagesLoaded)
        XCTAssertEqual(bestie.sentByOwner, 3)
        XCTAssertEqual(loaded.conversations.first { $0.id.rawValue == "t2" }?.messagesLoaded, false)
    }

    func testFocusedLoadReportsMessagesFoundForThatChat() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibraryStore(root: directory)
        let session = Self.session(userID: fake.ownerID)
        _ = try await InstagramInboxSync(client: fake, library: library, listingDelay: 0, clock: ManualClock())
            .list(session: session)

        var headlines: [String] = []
        var details: [String] = []
        let loaded = try await InstagramInboxSync(client: fake, library: library, listingDelay: 0, clock: ManualClock())
            .load(session: session, ids: [ConversationID("t1")], titles: ["t1": "@maya"]) { progress in
                headlines.append(progress.headline)
                details.append(progress.detail)
            }
        let chat = try XCTUnwrap(loaded.conversations.first { $0.id.rawValue == "t1" })
        XCTAssertTrue(chat.messagesLoaded)
        XCTAssertEqual(chat.sentByOwner, 3)
        XCTAssertTrue(headlines.contains(where: { $0.hasPrefix("Reading ") }))
        XCTAssertTrue(details.contains(where: { $0.hasSuffix("messages found so far") }))
        XCTAssertEqual(loaded.conversations.first { $0.id.rawValue == "t2" }?.messagesLoaded, false)
    }

    func testUnsendOnlyDeletesOwnerItems() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let service = InstagramWebUnsendService(client: fake, ownerID: { fake.ownerID })
        let own = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("t1"), messageID: "m1"),
            authorID: ParticipantID("ig:" + fake.ownerID),
            sentAt: Date(),
            kind: .text
        )
        let ownResult = try await service.unsend(own)
        XCTAssertEqual(ownResult, .unsent)
        XCTAssertEqual(fake.deletedIDs, ["m1"])

        let foreign = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("t1"), messageID: "m2"),
            authorID: ParticipantID("ig:7"),
            sentAt: Date(),
            kind: .text
        )
        let foreignResult = try await service.unsend(foreign)
        XCTAssertEqual(foreignResult, .notOwned)
        XCTAssertEqual(fake.deletedIDs, ["m1"])
        XCTAssertEqual(fake.remaining(in: "t1").map(\.id).sorted(), ["m2", "m3", "m4"])
    }

    func testUnsendIsIdempotentWhenAlreadyGone() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let service = InstagramWebUnsendService(client: fake, ownerID: { fake.ownerID })
        let target = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("t1"), messageID: "m1"),
            authorID: ParticipantID("ig:" + fake.ownerID),
            sentAt: Date(),
            kind: .text
        )
        let first = try await service.unsend(target)
        XCTAssertEqual(first, .unsent)
        let second = try await service.unsend(target)
        XCTAssertEqual(second, .alreadyGone)
        let presence = try await service.presence(of: target)
        XCTAssertEqual(presence, .gone)
    }

    func testRateLimitAndCheckpointStopWithoutBypass() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let service = InstagramWebUnsendService(client: fake, ownerID: { fake.ownerID })
        let target = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("t1"), messageID: "m3"),
            authorID: ParticipantID("ig:" + fake.ownerID),
            sentAt: Date(),
            kind: .media
        )
        fake.script(.rateLimited, onCall: 1)
        do {
            _ = try await service.unsend(target)
            XCTFail("expected rate limit")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .rateLimited(retryAfter: nil))
        }
        fake.script(.verificationRequired, onCall: 2)
        do {
            _ = try await service.unsend(target)
            XCTFail("expected verification")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .verificationRequired)
        }
        XCTAssertTrue(fake.deletedIDs.isEmpty)
    }

    func testExpiredSessionSurfacesAsSessionExpired() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        fake.setPersistent(.sessionExpired)
        let service = InstagramWebUnsendService(client: fake, ownerID: { fake.ownerID })
        let target = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("t1"), messageID: "m1"),
            authorID: ParticipantID("ig:" + fake.ownerID),
            sentAt: Date(),
            kind: .text
        )
        do {
            _ = try await service.unsend(target)
            XCTFail("expected expiry")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .sessionExpired)
        }
    }

    func testMissingSessionDoesNotSend() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let service = InstagramWebUnsendService(client: fake, ownerID: { nil })
        let target = CleanupTarget(
            ref: MessageRef(conversationID: ConversationID("t1"), messageID: "m1"),
            authorID: ParticipantID("ig:" + fake.ownerID),
            sentAt: Date(),
            kind: .text
        )
        do {
            _ = try await service.unsend(target)
            XCTFail("expected expiry")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .sessionExpired)
        }
        XCTAssertEqual(fake.deleteCalls, 0)
    }

    func testEngineRunsLiveUnsendAgainstFakeWebsite() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibraryStore(root: directory)
        let session = Self.session(userID: fake.ownerID)
        let overview = try await InstagramInboxSync(client: fake, library: library, listingDelay: 0, clock: ManualClock())
            .run(session: session)

        let store = InMemoryJobStore()
        let account = try await library.account()
        _ = try await QueueBuilder(source: library, store: store, pageSize: 10, batchSize: 10)
            .build(request: .init(scope: .everything), account: account, conversations: overview.conversations, now: Date())

        let unsender = InstagramWebUnsendService(client: fake, ownerID: { fake.ownerID })
        let engine = try CleanupEngine(
            persisted: try XCTUnwrap(try store.loadActiveJob()),
            dependencies: CleanupEngineDependencies(
                store: store,
                unsender: unsender,
                policy: .demo,
                clock: ManualClock(),
                random: SeededRandom(seed: 1)
            )
        )
        try await engine.authorize()
        try await engine.start()
        await engine.waitUntilStopped()
        let progress = await engine.progress()
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.completed, 4)
        XCTAssertEqual(Set(fake.deletedIDs).count, 4)
        XCTAssertTrue(fake.remaining(in: "t1").allSatisfy { $0.userID != fake.ownerID })
    }

    func testClassifierMapsSafetySignals() {
        XCTAssertEqual(
            InstagramResponseClassifier.classify(Self.body(["message": "login_required", "status": "fail"], status: 200), destructive: true),
            .sessionExpired
        )
        XCTAssertEqual(
            InstagramResponseClassifier.classify(Self.body(["checkpoint_required": true], status: 403), destructive: true),
            .verificationRequired
        )
        XCTAssertEqual(
            InstagramResponseClassifier.classify(Self.body(["feedback_required": true, "spam": true], status: 200), destructive: false),
            .rateLimited(retryAfter: nil)
        )
        XCTAssertEqual(
            InstagramResponseClassifier.classify(HTTPResponse(statusCode: 429, headers: ["Retry-After": "30"], body: Data()), destructive: true),
            .rateLimited(retryAfter: 30)
        )
        XCTAssertNil(
            InstagramResponseClassifier.classify(Self.body(["status": "ok"], status: 200), destructive: true)
        )
        XCTAssertNil(
            InstagramResponseClassifier.classify(
                Self.body(["status": "fail", "message": "Item already deleted"], status: 200),
                destructive: true
            )
        )
        XCTAssertNil(
            InstagramResponseClassifier.classify(
                Self.body(
                    [
                        "status": "ok",
                        "inbox": [
                            "threads": [
                                ["thread_id": "1", "items": [["item_id": "m", "text": "this is spam and too many please wait a few minutes"]]],
                            ],
                        ],
                    ],
                    status: 200
                ),
                destructive: false
            )
        )
    }

    func testSessionNeverPrintsCookies() throws {
        let session = Self.session(userID: "42", sessionID: "super-secret-session-cookie-value")
        XCTAssertFalse("\(session)".contains("super-secret-session-cookie-value"))
        XCTAssertFalse(String(reflecting: session).contains("super-secret-session-cookie-value"))
        var dumped = ""
        dump(session, to: &dumped)
        XCTAssertFalse(dumped.contains("super-secret-session-cookie-value"))

        let vault = SessionVault(store: InMemorySecretStore())
        try vault.saveSession(session)
        XCTAssertEqual(try vault.loadSession()?.userID, "42")
        try vault.clear()
        XCTAssertNil(try vault.loadSession())
    }

    func testMalformedInboxStopsSafely() async throws {
        let fake = FakeInstagramAPIClient.sampleInbox()
        fake.script(.malformed, onCall: 1)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await InstagramInboxSync(client: fake, library: LocalLibraryStore(root: directory), listingDelay: 0, clock: ManualClock())
                .run(session: Self.session(userID: fake.ownerID))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .unexpectedResponse(code: 200))
        }
    }

    func testHTTPClientAttachesSessionAndRefusesWhenLoggedOut() async throws {
        let transport = RecordingTransport()
        transport.response = HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"status\":\"ok\"}".utf8))
        let vault = SessionVault(store: InMemorySecretStore())
        let client = InstagramHTTPClient(transport: transport, sessionProvider: { try vault.loadSession() })
        do {
            _ = try await client.send(InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/inbox/"))
            XCTFail("expected expiry")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .sessionExpired)
        }
        XCTAssertEqual(transport.calls, 0)

        try vault.saveSession(Self.session(userID: "42", sessionID: "cookie-value-xyz"))
        _ = try await client.send(InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/inbox/"))
        XCTAssertEqual(transport.calls, 2)
        let sent = try XCTUnwrap(transport.last)
        XCTAssertEqual(sent.url.host, "www.instagram.com")
        XCTAssertEqual(sent.url.scheme, "https")
        XCTAssertTrue(sent.url.path.contains("/api/v1/direct_v2/inbox/"))
        var dumpText = ""
        dump(sent, to: &dumpText)
        XCTAssertFalse(dumpText.contains("cookie-value-xyz"))
    }

    func testHTTPClientLogsNeverIncludeSessionMaterial() async throws {
        let transport = RecordingTransport()
        transport.response = HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"status\":\"ok\"}".utf8))
        let vault = SessionVault(store: InMemorySecretStore())
        try vault.saveSession(Self.session(userID: "42", sessionID: "cookie-value-xyz"))
        let sink = MemoryLogSink()
        let logger = AppLogger(category: "test", sink: sink, minimumLevel: .debug)
        let client = InstagramHTTPClient(transport: transport, sessionProvider: { try vault.loadSession() }, logger: logger)
        _ = try await client.send(InstagramAPIRequest(method: .get, path: "/api/v1/direct_v2/inbox/"))
        XCTAssertFalse(sink.lines.isEmpty)
        for line in sink.lines {
            XCTAssertFalse(line.contains("cookie-value-xyz"), line)
            XCTAssertFalse(line.contains("csrf-token"), line)
            XCTAssertFalse(line.lowercased().contains("sessionid="), line)
        }
    }

    func testHTTPClientRejectsAbsolutePaths() async throws {
        let transport = RecordingTransport()
        let vault = SessionVault(store: InMemorySecretStore())
        try vault.saveSession(Self.session(userID: "42"))
        let client = InstagramHTTPClient(transport: transport, sessionProvider: { try vault.loadSession() })
        do {
            _ = try await client.send(InstagramAPIRequest(method: .get, path: "https://evil.example/inbox"))
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .unexpectedResponse(code: nil))
        }
        XCTAssertEqual(transport.calls, 0)
    }

    func testHTTPClientAllowsInstagramApiHostForUnsend() async throws {
        let transport = RecordingTransport()
        transport.response = HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"status\":\"ok\"}".utf8))
        let vault = SessionVault(store: InMemorySecretStore())
        try vault.saveSession(Self.session(userID: "42", sessionID: "cookie-value-xyz"))
        let client = InstagramHTTPClient(transport: transport, sessionProvider: { try vault.loadSession() })
        _ = try await client.send(InstagramAPIRequest(
            method: .post,
            path: "/api/v1/direct_v2/threads/1/items/2/delete/",
            form: ["_uuid": "device", "_uid": "42"],
            host: InstagramWebConstants.apiHost,
            isIdempotent: false,
            destructive: true
        ))
        let sent = try XCTUnwrap(transport.last)
        XCTAssertEqual(sent.url.host, "i.instagram.com")
        XCTAssertTrue(sent.url.path.contains("/items/2/delete/"))
        XCTAssertEqual(sent.method, .post)
        XCTAssertNotNil(sent.body)
    }

    func testSessionFromCookiesRequiresInstagramLoginCookies() {
        let facebookOnly = [
            InstagramWebSession.Cookie(name: "sessionid", value: "fb-session", domain: ".facebook.com", path: "/", isSecure: true),
            InstagramWebSession.Cookie(name: "ds_user_id", value: "42", domain: ".facebook.com", path: "/", isSecure: true)
        ]
        XCTAssertNil(InstagramWebSession.from(cookies: facebookOnly))

        let missingCSRF = [
            InstagramWebSession.Cookie(name: "sessionid", value: "ig-session", domain: ".instagram.com", path: "/", isSecure: true),
            InstagramWebSession.Cookie(name: "ds_user_id", value: "42", domain: ".instagram.com", path: "/", isSecure: true)
        ]
        XCTAssertNil(InstagramWebSession.from(cookies: missingCSRF))

        let mixed = facebookOnly + missingCSRF + [
            InstagramWebSession.Cookie(name: "csrftoken", value: "csrf", domain: ".instagram.com", path: "/", isSecure: true)
        ]
        let session = InstagramWebSession.from(cookies: mixed)
        XCTAssertEqual(session?.userID, "42")
        XCTAssertEqual(session?.cookies.count, 3)
        XCTAssertFalse(session?.cookies.contains { $0.domain.contains("facebook") } ?? true)
    }

    func testLoginPolicyAllowsInstagramAndMetaSSOOnly() {
        XCTAssertTrue(InstagramLoginPolicy.allowsNavigation(to: URL(string: "https://www.instagram.com/accounts/login/")!))
        XCTAssertTrue(InstagramLoginPolicy.allowsNavigation(to: URL(string: "https://m.facebook.com/login.php")!))
        XCTAssertTrue(InstagramLoginPolicy.allowsNavigation(to: URL(string: "about:blank")!))
        XCTAssertFalse(InstagramLoginPolicy.allowsNavigation(to: URL(string: "http://www.instagram.com/accounts/login/")!))
        XCTAssertFalse(InstagramLoginPolicy.allowsNavigation(to: URL(string: "https://evil.example/")!))
        XCTAssertFalse(InstagramLoginPolicy.allowsNavigation(to: URL(string: "https://instagram.com.evil.example/")!))
        XCTAssertTrue(InstagramLoginPolicy.isDirectSurface(url: URL(string: "https://www.instagram.com/direct/inbox/")!))
        XCTAssertFalse(InstagramLoginPolicy.isDirectSurface(url: URL(string: "https://www.instagram.com/")!))
        XCTAssertFalse(InstagramLoginPolicy.isPostLogin(url: URL(string: "https://www.instagram.com/accounts/login/")!))
    }

    func testInboxParserAcceptsThreadV2IDsAndSkipsBrokenThreads() throws {
        let json = """
        {
          "status": "ok",
          "inbox": {
            "threads": [
              {"thread_v2_id": "t-v2", "thread_title": "Bestie", "users": []},
              {"thread_title": "no id"},
              {"thread_id": "t-classic", "thread_title": "Classic", "users": []}
            ],
            "has_older": false,
            "oldest_cursor": ""
          }
        }
        """.data(using: .utf8)!
        let page = try InstagramWebFormat.parseInbox(json)
        XCTAssertEqual(page.inbox?.threads.map(\.threadID.rawValue), ["t-v2", "t-classic"])
    }

    func testThreadParserClassifiesPhotosVsTexts() throws {
        let json = """
        {"thread":{"items":[
          {"item_id":"1","user_id":"42","timestamp":1,"item_type":"text","text":"hi"},
          {"item_id":"2","user_id":"42","timestamp":1,"media":{"image_versions2":{}}},
          {"item_id":"3","user_id":"42","timestamp":1,"item_type":"text","media":{"video_versions":[]}},
          {"item_id":"4","user_id":"42","timestamp":1,"item_type":"media_share","media":{"image_versions2":{}}},
          {"item_id":"5","user_id":"42","timestamp":1,"voice_media":{}},
          {"item_id":"6","user_id":"42","timestamp":1,"item_type":"generic_xma","xma":{}},
          {"item_id":"7","user_id":"42","timestamp":1,"item_type":"raven_media"},
          {"item_id":"8","user_id":"42","timestamp":1,"item_type":"placeholder"}
        ]}}
        """.data(using: .utf8)!
        let kinds = try XCTUnwrap(try InstagramWebFormat.parseThread(json).thread?.items?.map(\.kind))
        XCTAssertEqual(kinds, [.text, .media, .media, .link, .voice, .link, .media, .other])
    }

    func testItemKindDoesNotDefaultMissingTypeToText() {
        XCTAssertEqual(
            InstagramItemKind.classify(itemType: nil, hasVoice: false, hasPhotoVideo: true, hasShareOrLink: false, hasText: true),
            .media
        )
        XCTAssertEqual(
            InstagramItemKind.classify(itemType: "text", hasVoice: false, hasPhotoVideo: false, hasShareOrLink: true, hasText: true),
            .link
        )
        XCTAssertEqual(
            InstagramItemKind.classify(itemType: nil, hasVoice: false, hasPhotoVideo: false, hasShareOrLink: false, hasText: true),
            .text
        )
    }

    private static func session(userID: String, sessionID: String = "session-token") -> InstagramWebSession {
        InstagramWebSession(cookies: [
            .init(name: "sessionid", value: sessionID, domain: ".instagram.com", path: "/", isSecure: true),
            .init(name: "csrftoken", value: "csrf-token", domain: ".instagram.com", path: "/", isSecure: true),
            .init(name: "ds_user_id", value: userID, domain: ".instagram.com", path: "/", isSecure: true)
        ], userID: userID)
    }

    private static func body(_ object: [String: Any], status: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    var response = HTTPResponse(statusCode: 200, headers: [:], body: Data())
    private(set) var calls = 0
    private(set) var last: HTTPRequest?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        last = request
        return response
    }
}
