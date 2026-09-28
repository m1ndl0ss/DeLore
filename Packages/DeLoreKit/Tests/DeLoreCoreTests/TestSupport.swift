@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

struct EngineHarness {
    let fake: FakeInstagramService
    let store: JobStore
    let clock: ManualClock
    let analytics: RecordingAnalyticsSink
    let logs: MemoryLogSink
    let policy: RatePolicy

    init(
        fake: FakeInstagramService = EngineHarness.standardFake(),
        store: JobStore = InMemoryJobStore(),
        clock: ManualClock = ManualClock(),
        policy: RatePolicy = .conservative
    ) {
        self.fake = fake
        self.store = store
        self.clock = clock
        self.policy = policy
        analytics = RecordingAnalyticsSink()
        logs = MemoryLogSink()
    }

    static func standardFake(messages: Int = 60, ownerShare: Int = 50) -> FakeInstagramService {
        FakeInstagramService(conversations: [
            .init(id: "conv-a", title: "a", messageCount: messages, ownerShare: ownerShare),
            .init(id: "conv-b", title: "b", messageCount: messages / 2, ownerShare: ownerShare)
        ])
    }

    var dependencies: CleanupEngineDependencies {
        CleanupEngineDependencies(
            store: store,
            unsender: fake,
            policy: policy,
            clock: clock,
            random: SeededRandom(seed: 99),
            analytics: Analytics(sink: analytics, isEnabled: true),
            logger: AppLogger(category: "test", sink: logs, minimumLevel: .debug)
        )
    }

    @discardableResult
    func buildJob(_ request: CleanupRequest = CleanupRequest(scope: .everything), pageSize: Int = 50, batchSize: Int = 25) async throws -> QueueBuildReport {
        let account = try await fake.account()
        let conversations = try await fake.conversations()
        return try await QueueBuilder(source: fake, store: store, pageSize: pageSize, batchSize: batchSize)
            .build(request: request, account: account, conversations: conversations, now: clock.now)
    }

    func makeEngine(authorize: Bool = true) async throws -> CleanupEngine {
        let persisted = try XCTUnwrap(try store.loadActiveJob())
        let engine = try CleanupEngine(persisted: persisted, dependencies: dependencies)
        if authorize { try await engine.authorize() }
        return engine
    }

    func runToStop(_ engine: CleanupEngine, userResolvedIssue: Bool = false) async throws -> CleanupProgress {
        try await engine.start(userResolvedIssue: userResolvedIssue)
        await engine.waitUntilStopped()
        return await engine.progress()
    }

    func ownerMessageCount() async throws -> Int {
        try await fake.conversations().reduce(0) { $0 + $1.sentByOwner }
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("delore-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
