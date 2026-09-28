@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<HTTPResponse, NetworkError>]
    private(set) var calls = 0

    init(_ results: [Result<HTTPResponse, NetworkError>]) {
        self.results = results
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let result: Result<HTTPResponse, NetworkError> = lock.withLock {
            calls += 1
            return results.isEmpty ? .failure(.connectionLost) : results.removeFirst()
        }
        return try result.get()
    }
}

final class NetworkingTests: XCTestCase {
    private let url = URL(string: "https://example.com/resource")!
    private func ok() -> HTTPResponse { HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"value\":1}".utf8)) }

    func testIdempotentRequestsRetryTransientFailures() async throws {
        let transport = ScriptedTransport([.failure(.timedOut), .failure(.connectionLost), .success(ok())])
        let client = HTTPClient(transport: transport, clock: ManualClock(), random: SeededRandom(seed: 1))
        _ = try await client.send(HTTPRequest(method: .get, url: url))
        XCTAssertEqual(transport.calls, 3)
    }

    func testDestructiveRequestsAreNeverRetriedByTransport() async throws {
        let transport = ScriptedTransport([.failure(.timedOut), .success(ok())])
        let client = HTTPClient(transport: transport, clock: ManualClock(), random: SeededRandom(seed: 1))
        do {
            _ = try await client.send(HTTPRequest(method: .post, url: url))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? NetworkError, .timedOut)
        }
        XCTAssertEqual(transport.calls, 1)
    }

    func testRetriesAreBounded() async throws {
        let transport = ScriptedTransport(Array(repeating: .failure(.timedOut), count: 10))
        let client = HTTPClient(transport: transport, retry: TransportRetryPolicy(maxAttempts: 3), clock: ManualClock(), random: SeededRandom(seed: 1))
        _ = try? await client.send(HTTPRequest(method: .get, url: url))
        XCTAssertEqual(transport.calls, 3)
    }

    func testStatusCodesMapToIntegrationErrors() async throws {
        let transport = ScriptedTransport([.success(HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data()))])
        let client = HTTPClient(transport: transport, clock: ManualClock(), random: SeededRandom(seed: 1))
        do {
            _ = try await client.send(HTTPRequest(method: .get, url: url))
            XCTFail("expected failure")
        } catch let error as NetworkError {
            XCTAssertEqual(error, .status(429, retryAfter: 120))
            XCTAssertEqual(error.integrationError(destructive: true), .rateLimited(retryAfter: 120))
        }
        XCTAssertEqual(NetworkError.status(401, retryAfter: nil).integrationError(destructive: false), .sessionExpired)
        XCTAssertEqual(NetworkError.status(503, retryAfter: nil).integrationError(destructive: true), .serverUnavailable)
        XCTAssertEqual(NetworkError.status(400, retryAfter: nil).integrationError(destructive: true), .unexpectedResponse(code: 400))
        XCTAssertEqual(NetworkError.offline.integrationError(destructive: true), .offline)
        XCTAssertEqual(NetworkError.timedOut.integrationError(destructive: true), .transportFailure(requestMayHaveBeenApplied: true))
        XCTAssertEqual(NetworkError.timedOut.integrationError(destructive: false), .transportFailure(requestMayHaveBeenApplied: false))
    }

    func testTypedDecoding() async throws {
        struct Value: Decodable { let value: Int }
        let client = HTTPClient(transport: ScriptedTransport([.success(ok())]), clock: ManualClock())
        let decoded = try await client.send(HTTPRequest(method: .get, url: url), decoding: Value.self)
        XCTAssertEqual(decoded.value, 1)
    }

    func testPlainHTTPIsRefused() async throws {
        let transport = URLSessionTransport()
        do {
            _ = try await transport.send(HTTPRequest(method: .get, url: URL(string: "http://example.com")!))
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? NetworkError, .insecureConnection)
        }
    }

    func testCancellationPropagates() async throws {
        let client = HTTPClient(transport: ScriptedTransport(Array(repeating: .failure(.timedOut), count: 5)), clock: SystemClock())
        let request = HTTPRequest(method: .get, url: url)
        let task = Task { try await client.send(request) }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get())
    }
}

final class EntitlementTests: XCTestCase {
    func testProUnlocksEverything() {
        let decision = CleanupAllowance.evaluate(requestedCount: 10_000, usesAdvancedFilters: true, entitlement: EntitlementState(isPro: true), freeLimit: 50)
        XCTAssertEqual(decision, .allowed(limit: nil, consumesPass: false, usesFreeAllowance: false))
    }

    func testFiltersRequirePro() {
        let decision = CleanupAllowance.evaluate(requestedCount: 5, usesAdvancedFilters: true, entitlement: EntitlementState(cleanupPasses: 1), freeLimit: 50)
        XCTAssertEqual(decision, .filtersRequirePro)
    }

    func testPassAllowsFullCleanup() {
        let decision = CleanupAllowance.evaluate(requestedCount: 10_000, usesAdvancedFilters: false, entitlement: EntitlementState(cleanupPasses: 1), freeLimit: 50)
        XCTAssertEqual(decision, .allowed(limit: nil, consumesPass: true, usesFreeAllowance: false))
    }

    func testFreeAllowanceIsLifetimeLimited() {
        XCTAssertEqual(
            CleanupAllowance.evaluate(requestedCount: 20, usesAdvancedFilters: false, entitlement: EntitlementState(freeMessagesUsed: 10), freeLimit: 50),
            .allowed(limit: 20, consumesPass: false, usesFreeAllowance: true)
        )
        XCTAssertEqual(
            CleanupAllowance.evaluate(requestedCount: 100, usesAdvancedFilters: false, entitlement: EntitlementState(freeMessagesUsed: 10), freeLimit: 50),
            .limited(remainingFree: 40)
        )
        XCTAssertEqual(
            CleanupAllowance.evaluate(requestedCount: 1, usesAdvancedFilters: false, entitlement: EntitlementState(freeMessagesUsed: 80), freeLimit: 50),
            .limited(remainingFree: 0)
        )
    }

    func testFilterMatching() {
        let date = Date(timeIntervalSince1970: 1_000)
        let message = DiscoveredMessage(ref: MessageRef(conversationID: ConversationID("c"), messageID: "1"), authorID: ParticipantID("o"), sentAt: date, kind: .media)
        XCTAssertTrue(CleanupFilter.none.matches(message))
        XCTAssertTrue(CleanupFilter(kinds: [.media]).matches(message))
        XCTAssertFalse(CleanupFilter(kinds: [.text]).matches(message))
        XCTAssertFalse(CleanupFilter(sentAfter: date.addingTimeInterval(1)).matches(message))
        XCTAssertFalse(CleanupFilter(sentBefore: date.addingTimeInterval(-1)).matches(message))
        XCTAssertTrue(CleanupFilter(sentAfter: date, sentBefore: date).matches(message))
    }

    func testFilteredJobOnlyContainsMatchingMessages() async throws {
        let harness = EngineHarness()
        let request = CleanupRequest(scope: .conversations([ConversationID("conv-a")]), filter: CleanupFilter(kinds: [.media]))
        try await harness.buildJob(request)
        let items = try XCTUnwrap(try harness.store.loadActiveJob()).items
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.kind == .media && $0.ref.conversationID.rawValue == "conv-a" })
        let estimate = QueueBuilder.estimatedCount(for: request, in: try await harness.fake.conversations())
        XCTAssertEqual(estimate, items.count)
    }
}
