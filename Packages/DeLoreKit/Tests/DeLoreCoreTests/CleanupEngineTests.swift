@testable import DeLoreCore
import DeLoreFakes
import Foundation
import XCTest

final class CleanupEngineTests: XCTestCase {
    // MARK: Ownership

    func testOnlyUserAuthoredMessagesAreQueued() async throws {
        let harness = EngineHarness()
        let report = try await harness.buildJob()
        let items = try XCTUnwrap(try harness.store.loadActiveJob()).items

        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.authorID == harness.fake.owner.ownerID })
        let expectedCount = try await harness.ownerMessageCount()
        XCTAssertEqual(items.count, expectedCount)
        XCTAssertGreaterThan(report.excludedNotOwned, 0)
    }

    func testReceivedMessagesAreNeverQueuedOrUnsent() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .completed)
        XCTAssertTrue(harness.fake.foreignAttempts.isEmpty)
        let summaries = try await harness.fake.conversations()
        XCTAssertEqual(summaries.reduce(0) { $0 + $1.sentByOwner }, 0, "all owner messages gone")
        XCTAssertGreaterThan(summaries.reduce(0) { $0 + $1.receivedFromOthers }, 0, "received messages untouched")
    }

    func testEngineRefusesForeignItemsEvenIfStoreIsTampered() async throws {
        let harness = EngineHarness()
        let job = CleanupJob(createdAt: harness.clock.now, ownerID: harness.fake.owner.ownerID, request: .init(scope: .everything), itemCount: 2)
        try harness.store.createJob(job)
        try harness.store.appendItems([
            CleanupItem(index: 0, ref: MessageRef(conversationID: ConversationID("conv-a"), messageID: "m0"), authorID: harness.fake.other, sentAt: Date(), kind: .text),
            CleanupItem(index: 1, ref: MessageRef(conversationID: ConversationID("conv-a"), messageID: "m1"), authorID: harness.fake.other, sentAt: Date(), kind: .text)
        ])
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.skipped, 2)
        XCTAssertEqual(harness.fake.unsendCalls, 0)
    }

    func testPlatformNotOwnedResponseIsSkipped() async throws {
        let harness = EngineHarness()
        let foreign = MessageRef(conversationID: ConversationID("conv-a"), messageID: "m0")
        let isForeign = try await isOwnedByOther(foreign, fake: harness.fake)
        let job = CleanupJob(createdAt: harness.clock.now, ownerID: harness.fake.owner.ownerID, request: .init(scope: .everything), itemCount: 1)
        try harness.store.createJob(job)
        // The item claims to be ours; the platform disagrees.
        try harness.store.appendItems([CleanupItem(index: 0, ref: foreign, authorID: harness.fake.owner.ownerID, sentAt: Date(), kind: .text)])
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        if isForeign {
            XCTAssertEqual(progress.skipped, 1)
            XCTAssertEqual(harness.fake.removedCount, 0)
        } else {
            XCTAssertEqual(progress.completed, 1)
        }
    }

    // MARK: Duplicates

    func testDuplicateMessagesAreNotProcessedTwice() async throws {
        let fake = FakeInstagramService(conversations: [.init(id: "dup", title: "d", messageCount: 80, ownerShare: 60, duplicateEvery: 3)])
        let harness = EngineHarness(fake: fake)
        let report = try await harness.buildJob()
        XCTAssertGreaterThan(report.excludedDuplicates, 0)

        let items = try XCTUnwrap(try harness.store.loadActiveJob()).items
        XCTAssertEqual(Set(items.map(\.ref)).count, items.count)

        let engine = try await harness.makeEngine()
        _ = try await harness.runToStop(engine)
        XCTAssertTrue(fake.repeatedUnsends.isEmpty)
        XCTAssertEqual(fake.unsendCalls, items.count)
    }

    func testLedgerPreventsRequeueingCleanedMessages() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        let first = try await harness.runToStop(engine)
        XCTAssertGreaterThan(first.completed, 0)

        // A stale source (e.g. an old export) still lists the messages we already cleaned.
        let staleSource = EngineHarness.standardFake()
        let account = try await staleSource.account()
        let report = try await QueueBuilder(source: staleSource, store: harness.store)
            .build(request: .init(scope: .everything), account: account, conversations: try await staleSource.conversations(), now: harness.clock.now)
        XCTAssertEqual(report.job.itemCount, 0)
        XCTAssertEqual(report.excludedAlreadyCleaned, first.completed)
    }

    // MARK: Pause / resume / cancel

    func testPauseStopsAfterInFlightRequest() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 5 { await engine.pause() }
        }
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .paused(.user))
        XCTAssertEqual(harness.fake.unsendCalls, 5)
        XCTAssertEqual(progress.completed, 5, "the in-flight request finishes and is recorded")
    }

    func testResumeContinuesWhereItLeftOff() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 7 { await engine.pause() }
        }
        _ = try await harness.runToStop(engine)
        harness.fake.onUnsend(nil)

        let progress = try await harness.runToStop(engine)
        let total = try XCTUnwrap(try harness.store.loadActiveJob()).job.itemCount
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.completed, total)
        XCTAssertEqual(harness.fake.unsendCalls, total)
        XCTAssertTrue(harness.fake.repeatedUnsends.isEmpty)
    }

    func testCancellationStopsAndCancelsRemaining() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 3 { await engine.cancel() }
        }
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .cancelled)
        XCTAssertEqual(progress.completed, 3)
        XCTAssertEqual(progress.cancelled, progress.total - 3)
        XCTAssertEqual(harness.fake.unsendCalls, 3)
        do {
            try await engine.start()
            XCTFail("cancelled jobs can't restart")
        } catch {
            XCTAssertEqual(error as? CleanupEngineError, .finished)
        }
        let persisted = try XCTUnwrap(try harness.store.loadActiveJob())
        XCTAssertEqual(persisted.items.filter { $0.state == .cancelled }.count, progress.total - 3)
    }

    func testRequiresExplicitAuthorization() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine(authorize: false)
        do {
            try await engine.start()
            XCTFail("must not start without authorization")
        } catch {
            XCTAssertEqual(error as? CleanupEngineError, .notAuthorized)
        }
        XCTAssertEqual(harness.fake.unsendCalls, 0)
    }

    func testBackgroundSuspendAndAutomaticResume() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 4 { await engine.suspendForBackground() }
        }
        let paused = try await harness.runToStop(engine)
        XCTAssertEqual(paused.status, .paused(.appInBackground))
        harness.fake.onUnsend(nil)

        try await engine.resumeAfterBackground()
        await engine.waitUntilStopped()
        let progress = await engine.progress()
        XCTAssertEqual(progress.status, .completed)
    }

    // MARK: Restart & crash recovery

    func testAppRestartResumesCorrectly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileJobStore(root: directory, compactionThreshold: 7)
        let harness = EngineHarness(store: store)
        try await harness.buildJob()

        let first = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 10 { await first.pause() }
        }
        _ = try await harness.runToStop(first)
        harness.fake.onUnsend(nil)

        // Simulate being killed right after persisting intent for the next item.
        var persisted = try XCTUnwrap(try store.loadActiveJob())
        var job = persisted.job
        job.status = .running
        try store.updateJob(job)
        var inFlight = try XCTUnwrap(persisted.items.first { $0.state == .queued })
        inFlight.state = .processing
        inFlight.attempts = 1
        try store.record(inFlight)

        // "Relaunch": a brand-new store and engine reading from disk.
        let relaunchedStore = try FileJobStore(root: directory, compactionThreshold: 7)
        let relaunched = EngineHarness(fake: harness.fake, store: relaunchedStore, clock: harness.clock)
        let engine = try XCTUnwrap(try CleanupEngine.loadActive(dependencies: relaunched.dependencies))
        let restored = await engine.progress()
        XCTAssertEqual(restored.status, .paused(.interrupted))
        XCTAssertEqual(restored.completed, 10)

        persisted = try XCTUnwrap(try relaunchedStore.loadActiveJob())
        let recovered = persisted.items[inFlight.index]
        XCTAssertEqual(recovered.state, .retryWait)
        XCTAssertTrue(recovered.needsReconcile)

        let progress = try await relaunched.runToStop(engine)
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.completed, progress.total)
        XCTAssertEqual(harness.fake.presenceCalls, 1, "in-doubt item is verified before any new unsend")
        XCTAssertTrue(harness.fake.repeatedUnsends.isEmpty)
    }

    func testTerminationWhileBackgroundedRestoresAsInterrupted() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 3 { await engine.suspendForBackground() }
        }
        _ = try await harness.runToStop(engine)
        harness.fake.onUnsend(nil)

        let relaunched = try XCTUnwrap(try CleanupEngine.loadActive(dependencies: harness.dependencies))
        let restored = await relaunched.progress()
        XCTAssertEqual(restored.status, .paused(.interrupted))
        XCTAssertEqual(restored.completed, 3)
    }

    func testTornJournalWriteIsIgnoredOnLoad() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileJobStore(root: directory, compactionThreshold: 10_000)
        let harness = EngineHarness(store: store)
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 6 { await engine.pause() }
        }
        _ = try await harness.runToStop(engine)
        harness.fake.onUnsend(nil)

        let journal = directory.appendingPathComponent("active/journal.jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"i\",\"item\":{\"i\":0,\"s\":\"compl".utf8))
        try handle.close()

        let reloaded = try XCTUnwrap(try FileJobStore(root: directory).loadActiveJob())
        XCTAssertEqual(reloaded.items.filter { $0.state == .completed }.count, 6)
    }

    func testCompactionCrashReplayIsIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileJobStore(root: directory, compactionThreshold: 10_000)
        let harness = EngineHarness(store: store)
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 8 { await engine.pause() }
        }
        _ = try await harness.runToStop(engine)

        let journalURL = directory.appendingPathComponent("active/journal.jsonl")
        let journal = try Data(contentsOf: journalURL)
        let before = try XCTUnwrap(try store.loadActiveJob()).items

        // Crash between writing the snapshot and deleting the journal: both survive.
        try store.compact()
        try journal.write(to: journalURL)
        let after = try XCTUnwrap(try FileJobStore(root: directory).loadActiveJob()).items
        XCTAssertEqual(before, after)
    }

    func testIncompleteQueueBuildIsRejected() async throws {
        let store = InMemoryJobStore()
        let job = CleanupJob(createdAt: Date(), ownerID: ParticipantID("o"), request: .init(scope: .everything), itemCount: 5)
        try store.createJob(job)
        try store.appendItems([CleanupItem(index: 0, ref: MessageRef(conversationID: ConversationID("c"), messageID: "1"), authorID: ParticipantID("o"), sentAt: Date(), kind: .text)])
        let harness = EngineHarness(store: store)
        XCTAssertThrowsError(try CleanupEngine.loadActive(dependencies: harness.dependencies))
    }

    func testStorageFailureStopsBeforeDestructiveRequest() async throws {
        let store = InMemoryJobStore()
        let harness = EngineHarness(store: store)
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        // Records: 1 = processing(item0), 2 = completed(item0), 3 = processing(item1) → fails.
        store.failOnRecord = store.recordCount + 3
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .paused(.storageFailure))
        XCTAssertEqual(harness.fake.unsendCalls, 1, "no request is sent when intent can't be saved")
    }

    // MARK: Rate limiting

    func testRateLimitCausesBackoff() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.rateLimited(retryAfter: nil), onUnsendCall: 3)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertTrue(harness.clock.sleeps.contains { $0 >= harness.policy.rateLimitCooldown }, "cool-down applied")
        XCTAssertEqual(harness.fake.unsendCalls, progress.total + 1)
    }

    func testRetryAfterHeaderIsHonoured() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.rateLimited(retryAfter: 7_200), onUnsendCall: 2)
        let engine = try await harness.makeEngine()
        _ = try await harness.runToStop(engine)
        XCTAssertTrue(harness.clock.sleeps.contains { $0 >= 7_199 })
    }

    func testAdaptiveSlowdownAfterRateLimit() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.rateLimited(retryAfter: nil), onUnsendCall: 2)
        let engine = try await harness.makeEngine()
        _ = try await harness.runToStop(engine)

        let paceSleeps = harness.clock.sleeps.filter { $0 < harness.policy.rateLimitCooldown }
        let minimumSlowed = harness.policy.minimumDelay * harness.policy.slowdownFactor
        XCTAssertTrue(paceSleeps.suffix(5).allSatisfy { $0 >= minimumSlowed - 0.5 }, "gaps grow after a rate limit")
    }

    func testRepeatedRateLimitsEventuallyStopTheJob() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.setPersistentFault(.rateLimited(retryAfter: nil))
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .paused(.rateLimited))
        XCTAssertEqual(harness.fake.unsendCalls, harness.policy.maxConsecutiveRateLimits)
        let resumeAt = try XCTUnwrap(progress.resumeNotBefore)
        XCTAssertGreaterThan(resumeAt, harness.clock.now)

        do {
            try await engine.start()
            XCTFail("must respect the cool-down")
        } catch {
            XCTAssertEqual(error as? CleanupEngineError, .coolingDown(until: resumeAt))
        }

        harness.fake.setPersistentFault(nil)
        harness.clock.advance(by: resumeAt.timeIntervalSince(harness.clock.now) + 1)
        let resumed = try await harness.runToStop(engine)
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(resumed.failed, 0)
    }

    // MARK: Session & security responses

    func testAuthenticationExpirationPausesTheJob() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.sessionExpired, onUnsendCall: 4)
        let engine = try await harness.makeEngine()
        let paused = try await harness.runToStop(engine)

        XCTAssertEqual(paused.status, .paused(.sessionExpired))
        XCTAssertEqual(harness.fake.unsendCalls, 4)
        do {
            try await engine.start()
            XCTFail("must wait for the user to reconnect")
        } catch {
            XCTAssertEqual(error as? CleanupEngineError, .needsUserAction(.sessionExpired))
        }

        let resumed = try await harness.runToStop(engine, userResolvedIssue: true)
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(resumed.completed, resumed.total)
    }

    func testCheckpointResponseStopsTheJob() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.verificationRequired, onUnsendCall: 2)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .paused(.verificationRequired))
        XCTAssertEqual(harness.fake.unsendCalls, 2, "no further requests after a checkpoint")
        XCTAssertTrue(PauseReason.verificationRequired.requiresUserAction)
    }

    func testUnexpectedResponseFailsThatItemAndContinues() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.unexpected(code: 418), onUnsendCall: 1)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.completed, progress.total - 1)
    }

    func testUnavailableIntegrationPausesWithoutNetwork() async throws {
        let store = InMemoryJobStore()
        let harness = EngineHarness(store: store)
        try await harness.buildJob()
        var dependencies = harness.dependencies
        dependencies.unsender = UnavailableUnsendService()
        let engine = try CleanupEngine(persisted: XCTUnwrap(try store.loadActiveJob()), dependencies: dependencies)
        try await engine.authorize()
        try await engine.start()
        await engine.waitUntilStopped()
        let progress = await engine.progress()
        XCTAssertEqual(progress.status, .paused(.integrationUnavailable))
        XCTAssertEqual(progress.completed, 0)
        XCTAssertEqual(progress.failed, 0)
    }

    func testOfflinePausesWithoutConsumingAttempts() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.offline, onUnsendCall: 2)
        let engine = try await harness.makeEngine()
        let paused = try await harness.runToStop(engine)
        XCTAssertEqual(paused.status, .paused(.offline))
        let snapshot = await engine.itemsSnapshot()
        let item = try XCTUnwrap(snapshot.first { $0.state == .retryWait })
        XCTAssertEqual(item.attempts, 0)
        XCTAssertFalse(item.needsReconcile)
    }

    // MARK: Network failures & destructive safety

    func testNetworkFailuresRetrySafely() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.timeoutBeforeApplying, onUnsendCall: 2)
        harness.fake.scriptFault(.serverError, onUnsendCall: 5)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.completed, progress.total)
        XCTAssertEqual(harness.fake.presenceCalls, 2, "each ambiguous failure is reconciled first")
        XCTAssertTrue(harness.fake.repeatedUnsends.isEmpty)
        XCTAssertTrue(harness.clock.sleeps.contains { $0 >= harness.policy.backoffBase * 0.5 }, "backoff applied")
    }

    func testDestructiveActionsAreNotBlindlyRepeated() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.scriptFault(.timeoutAfterApplying, onUnsendCall: 2)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.completed, progress.total)
        // The lost-response item was verified as gone instead of being unsent again.
        XCTAssertEqual(harness.fake.unsendCalls, progress.total)
        XCTAssertEqual(harness.fake.presenceCalls, 1)
        XCTAssertTrue(harness.fake.repeatedUnsends.isEmpty)
    }

    func testPersistentFailuresAreBoundedAndPauseTheJob() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        harness.fake.setPersistentFault(.serverError)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .paused(.repeatedFailures))
        XCTAssertLessThanOrEqual(harness.fake.unsendCalls + harness.fake.presenceCalls, harness.policy.maxConsecutiveFailures * 2)
    }

    func testItemFailsAfterMaxAttemptsWithoutInfiniteLoop() async throws {
        let fake = FakeInstagramService(conversations: [.init(id: "one", title: "o", messageCount: 3, ownerShare: 100)])
        var policy = RatePolicy.conservative
        policy.maxConsecutiveFailures = 100
        let harness = EngineHarness(fake: fake, policy: policy)
        try await harness.buildJob()
        // Every unsend times out before applying; every reconcile confirms "present".
        fake.setPersistentFault(.timeoutBeforeApplying)
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.failed, 3)
        XCTAssertEqual(fake.unsendCalls, 3 * policy.maxAttemptsPerItem)
    }

    // MARK: Partial completion

    func testPartialCompletionIsRecoveredCorrectly() async throws {
        let harness = EngineHarness()
        try await harness.buildJob()
        let engine = try await harness.makeEngine()
        harness.fake.onUnsend { call in
            if call == 10 { await engine.pause() }
        }
        _ = try await harness.runToStop(engine)
        harness.fake.onUnsend(nil)

        // Meanwhile the user unsent a few messages by hand.
        let pending = await engine.itemsSnapshot().filter { $0.state == .queued }.prefix(4)
        pending.forEach { harness.fake.removeExternally($0.ref) }

        let progress = try await harness.runToStop(engine)
        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.completed, progress.total)
        XCTAssertEqual(progress.remaining, 0)
        let remainingOwned = try await harness.ownerMessageCount()
        XCTAssertEqual(remainingOwned, 0)
    }

    // MARK: Progress

    func testProgressCalculationRemainsCorrect() async throws {
        let fake = FakeInstagramService(conversations: [.init(id: "p", title: "p", messageCount: 40, ownerShare: 100)])
        var policy = RatePolicy.conservative
        policy.maxConsecutiveFailures = 100
        let harness = EngineHarness(fake: fake, policy: policy)
        try await harness.buildJob()
        let engine = try await harness.makeEngine()

        let initial = await engine.progress()
        XCTAssertEqual(initial.total, 40)
        XCTAssertEqual(initial.fraction, 0)
        XCTAssertNil(initial.estimatedSecondsRemaining, "no estimate before observing real speed")

        harness.fake.onUnsend { call in
            if call == 20 { await engine.pause() }
        }
        let mid = try await harness.runToStop(engine)
        XCTAssertEqual(mid.completed, 20)
        XCTAssertEqual(mid.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mid.remaining, 20)
        let estimate = try XCTUnwrap(mid.estimatedSecondsRemaining, "estimate based on observed speed")
        XCTAssertGreaterThan(estimate, 20 * harness.policy.minimumDelay * 0.9)

        harness.fake.onUnsend(nil)
        let stream = await engine.updates()
        try await engine.start()
        var observedFractions: [Double] = []
        for await update in stream {
            observedFractions.append(update.fraction)
        }
        XCTAssertEqual(observedFractions, observedFractions.sorted(), "progress never goes backwards")
        let final = await engine.progress()
        XCTAssertEqual(final.fraction, 1)
        XCTAssertEqual(final.processed, final.total)
    }

    // MARK: Scale

    func testLargeConversationsStayBounded() async throws {
        let fake = FakeInstagramService(conversations: [.init(id: "huge", title: "h", messageCount: 200_000, ownerShare: 50)])
        let harness = EngineHarness(fake: fake)
        let report = try await harness.buildJob(pageSize: 200, batchSize: 500)

        XCTAssertLessThanOrEqual(fake.maximumPageSizeServed, 200)
        XCTAssertGreaterThanOrEqual(fake.pagesServedCount, 1_000)
        XCTAssertLessThanOrEqual(report.peakBufferedItems, 500)
        XCTAssertGreaterThan(report.job.itemCount, 90_000)
    }

    func testLargeJobRunsToCompletion() async throws {
        let fake = FakeInstagramService(conversations: [.init(id: "big", title: "b", messageCount: 6_000, ownerShare: 100)])
        let harness = EngineHarness(fake: fake)
        try await harness.buildJob(CleanupRequest(scope: .everything, limit: 3_000))
        let engine = try await harness.makeEngine()
        let progress = try await harness.runToStop(engine)

        XCTAssertEqual(progress.total, 3_000)
        XCTAssertEqual(progress.completed, 3_000)
        // Pacing: never faster than the configured minimum gap on average.
        XCTAssertGreaterThanOrEqual(harness.clock.totalSlept, Double(2_999) * harness.policy.minimumDelay)
    }

    // MARK: Helpers

    private func isOwnedByOther(_ ref: MessageRef, fake: FakeInstagramService) async throws -> Bool {
        let target = CleanupTarget(ref: ref, authorID: fake.owner.ownerID, sentAt: Date(), kind: .text)
        return try await fake.presence(of: target) == .notOwned
    }
}
