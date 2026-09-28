@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

final class SecurityPrivacyTests: XCTestCase {
    // MARK: Logout

    func testLogoutRemovesSensitiveLocalState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let jobs = try FileJobStore(root: directory.appendingPathComponent("jobs"))
        let library = LocalLibraryStore(root: directory.appendingPathComponent("library"))
        let temp = directory.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: temp.appendingPathComponent("scratch"))

        try SessionVault(store: secrets).save(Sensitive(Data("session-material".utf8)))
        try secrets.set("3", for: "entitlements.passes")
        let writer = try library.beginImport(account: AccountIdentity(ownerID: ParticipantID("o"), displayName: "me"))
        try writer.add(
            summary: ConversationSummary(id: ConversationID("c"), title: "friend", sentByOwner: 1, receivedFromOthers: 1, firstSentAt: nil, lastSentAt: nil),
            messages: [DiscoveredMessage(ref: MessageRef(conversationID: ConversationID("c"), messageID: "1"), authorID: ParticipantID("o"), sentAt: Date(), kind: .text)]
        )
        _ = try writer.commit()
        try jobs.createJob(CleanupJob(createdAt: Date(), ownerID: ParticipantID("o"), request: .init(scope: .everything)))
        try jobs.addToLedger(["c|1"])

        try LocalDataEraser(
            secrets: secrets,
            jobs: jobs,
            library: library,
            extraDirectories: [temp],
            preservedSecretKeys: ["entitlements.passes"]
        ).eraseAll()

        XCTAssertFalse(SessionVault(store: secrets).hasSession)
        XCTAssertEqual(try secrets.string(for: "entitlements.passes"), "3", "purchases aren't erased")
        XCTAssertNil(try jobs.loadActiveJob())
        XCTAssertTrue(try jobs.loadLedger().isEmpty)
        XCTAssertFalse(library.hasLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        let reopened = LocalLibraryStore(root: directory.appendingPathComponent("library"))
        XCTAssertFalse(reopened.hasLibrary)
    }

    // MARK: Logs

    func testRedactorRemovesSecrets() {
        let samples = [
            "Cookie: sessionid=31337abcdef; csrftoken=XyZ123secret; ds_user_id=5551234567",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
            "{\"access_token\": \"IGQVJYabc123def456\"}",
            "GET https://i.instagram.com/api/v1/direct_v2/threads/340282366841710300949128/items/?cursor=abc",
            "password=hunter2 user@example.com"
        ]
        let secrets = ["31337abcdef", "XyZ123secret", "5551234567", "eyJhbGciOiJIUzI1NiJ9", "IGQVJYabc123def456",
                       "340282366841710300949128", "cursor=abc", "hunter2", "user@example.com"]
        for sample in samples {
            let redacted = Redactor.redact(sample)
            for secret in secrets {
                XCTAssertFalse(redacted.contains(secret), "\(secret) leaked in \(redacted)")
            }
        }
    }

    func testSensitiveWrapperNeverPrints() {
        let secret = Sensitive("sessionid-value-123")
        XCTAssertEqual("\(secret)", Redactor.placeholder)
        XCTAssertEqual(String(reflecting: secret), Redactor.placeholder)
        var dumped = ""
        dump(secret, to: &dumped)
        XCTAssertFalse(dumped.contains("sessionid-value-123"))

        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://example.com/unsend")!,
            headers: ["Cookie": Sensitive("sessionid=topsecret")],
            body: Sensitive(Data("token=abc".utf8))
        )
        var requestDump = ""
        dump(request, to: &requestDump)
        XCTAssertFalse(requestDump.contains("topsecret"))
        XCTAssertFalse(String(describing: request).contains("topsecret"))
    }

    func testNoSecretsOrIdentifiersWrittenToLogs() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.timeoutAfterApplying, onUnsendCall: 2)
        harness.fake.scriptFault(.rateLimited(retryAfter: 30), onUnsendCall: 4)
        harness.fake.scriptFault(.unexpected(code: 499), onUnsendCall: 6)
        let engine = try await harness.makeEngine()
        _ = try await harness.runToStop(engine)
        _ = try await harness.runToStop(engine)

        let logger = AppLogger(category: "test", sink: harness.logs, minimumLevel: .debug)
        logger.error("request failed with Cookie: sessionid=abc123456789; token=zzz999")
        logger.info("thread 340282366841710300949128 failed")

        let lines = harness.logs.lines
        XCTAssertFalse(lines.isEmpty)
        let forbidden = ["conv-a", "conv-b", "abc123456789", "zzz999", "340282366841710300949128", "fake:owner", "fake:other"]
        for line in lines {
            for fragment in forbidden {
                XCTAssertFalse(line.contains(fragment), "log line leaks \(fragment): \(line)")
            }
            XCTAssertNil(line.range(of: "\\bm\\d+\\b", options: .regularExpression), "message id in \(line)")
        }
    }

    func testDisabledLoggerWritesNothingBelowMinimumLevel() {
        let sink = MemoryLogSink()
        let logger = AppLogger(category: "release", sink: sink, minimumLevel: .warning)
        logger.debug("debug detail")
        logger.info("info detail")
        logger.warning("warn")
        XCTAssertEqual(sink.lines.count, 1)
    }

    // MARK: Analytics

    func testAnalyticsPayloadsContainNoSensitiveData() async throws {
        let harness = EngineHarness()
        try await harness.buildJob(CleanupRequest(scope: .conversations([ConversationID("conv-a")])))
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 3 { await engine.pause() }
        }
        _ = try await harness.runToStop(engine)
        harness.fake.onUnsend(nil)
        _ = try await harness.runToStop(engine)

        let analytics = Analytics(sink: harness.analytics, isEnabled: true)
        analytics.track(.importCompleted(size: .init(count: 8_923)))
        analytics.track(.purchaseCompleted(product: .proYearly))

        let payloads = harness.analytics.payloads
        XCTAssertTrue(payloads.contains { $0.name == "cleanup_started" })
        XCTAssertTrue(payloads.contains { $0.name == "cleanup_completed" })
        let total = try XCTUnwrap(try harness.store.loadActiveJob()).job.itemCount
        for payload in payloads {
            XCTAssertTrue(Analytics.isSafe(payload))
            let values = [payload.name] + Array(payload.properties.keys) + Array(payload.properties.values)
            for value in values {
                XCTAssertFalse(value.contains("conv"), "conversation id in \(payload)")
                XCTAssertFalse(value.contains("fake:"), "participant id in \(payload)")
                XCTAssertNotEqual(value, "\(total)", "exact counts are bucketed")
                XCTAssertNotEqual(value, "8923")
            }
        }
    }

    func testUnsafeAnalyticsPayloadIsRejected() {
        XCTAssertFalse(Analytics.isSafe(AnalyticsPayload(name: "cleanup_started", properties: ["user": "Maya Smith"])))
        XCTAssertFalse(Analytics.isSafe(AnalyticsPayload(name: "cleanup_started", properties: ["thread": "340282366841710300949128"])))
        XCTAssertFalse(Analytics.isSafe(AnalyticsPayload(name: "Hey there", properties: [:])))
        XCTAssertTrue(Analytics.isSafe(AnalyticsPayload(name: "cleanup_started", properties: ["scope": "everything"])))
    }

    func testDisabledAnalyticsSendsNothing() {
        let sink = RecordingAnalyticsSink()
        Analytics(sink: sink, isEnabled: false).track(.onboardingStarted)
        XCTAssertTrue(sink.payloads.isEmpty)
    }

    func testSizeBuckets() {
        XCTAssertEqual(AnalyticsEvent.SizeBucket(count: 0), .none)
        XCTAssertEqual(AnalyticsEvent.SizeBucket(count: 49), .tiny)
        XCTAssertEqual(AnalyticsEvent.SizeBucket(count: 50), .small)
        XCTAssertEqual(AnalyticsEvent.SizeBucket(count: 4_999), .medium)
        XCTAssertEqual(AnalyticsEvent.SizeBucket(count: 1_000_000), .large)
    }

    // MARK: Secrets

    func testSecretStoreRoundTripAndRemoval() throws {
        let store = InMemorySecretStore()
        try store.set("value", for: "k")
        XCTAssertEqual(try store.string(for: "k"), "value")
        try store.removeValue(for: "k")
        XCTAssertNil(try store.string(for: "k"))
        try store.set("a", for: "1")
        try store.removeAll()
        XCTAssertTrue(store.isEmpty)
    }
}
