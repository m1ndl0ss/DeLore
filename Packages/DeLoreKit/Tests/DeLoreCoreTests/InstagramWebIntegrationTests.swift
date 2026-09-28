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
        XCTAssertEqual(transport.calls, 1)
        let sent = try XCTUnwrap(transport.last)
        XCTAssertEqual(sent.url.host, "www.instagram.com")
        XCTAssertEqual(sent.url.scheme, "https")
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
