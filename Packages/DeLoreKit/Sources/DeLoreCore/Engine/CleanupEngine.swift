import Foundation

public enum CleanupEngineError: Error, Equatable, Sendable {
    case notAuthorized
    case alreadyRunning
    case finished
    case needsUserAction(PauseReason)
    case coolingDown(until: Date)
}

public struct CleanupEngineDependencies: Sendable {
    public var store: JobStore
    public var unsender: UnsendService
    public var policy: RatePolicy
    public var clock: EngineClock
    public var random: RandomSource
    public var analytics: Analytics
    public var logger: AppLogger
    public var history: CleanupHistoryStore?

    public init(
        store: JobStore,
        unsender: UnsendService,
        policy: RatePolicy = .conservative,
        clock: EngineClock = SystemClock(),
        random: RandomSource = SystemRandom(),
        analytics: Analytics = .disabled,
        logger: AppLogger = .disabled,
        history: CleanupHistoryStore? = nil
    ) {
        self.store = store
        self.unsender = unsender
        self.policy = policy
        self.clock = clock
        self.random = random
        self.analytics = analytics
        self.logger = logger
        self.history = history
    }
}

/// Runs one cleanup job: paces destructive requests, persists every state change before and
/// after each request, reconciles anything in doubt, and stops on anything that looks like
/// the platform asking us to back off.
public actor CleanupEngine {
    private let deps: CleanupEngineDependencies
    private let logger: AppLogger
    private var job: CleanupJob
    private var items: [CleanupItem]
    private var throttler: Throttler
    private var estimator = ThroughputEstimator()
    private var queueCursor = 0
    private var retryIndices = Set<Int>()
    private var consecutiveFailures = 0
    private var counts: [CleanupItemState: Int] = [:]
    private var runTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<CleanupProgress>.Continuation] = [:]

    public var jobID: UUID { job.id }
    public var currentJob: CleanupJob { job }

    /// Restores an engine from persisted state, recovering from any interrupted run.
    public init(persisted: PersistedJob, dependencies: CleanupEngineDependencies) throws {
        var job = persisted.job
        var items = persisted.items
        guard items.count == job.itemCount else { throw JobStoreError.corrupted }

        var retryIndices = Set<Int>()
        var counts: [CleanupItemState: Int] = [:]
        for index in items.indices {
            switch items[index].state {
            case .processing:
                // Crashed or was killed mid-request: we can't know whether it was applied.
                items[index].state = .retryWait
                items[index].needsReconcile = true
                items[index].nextAttemptAt = nil
                try dependencies.store.record(items[index])
            case .discovered:
                items[index].state = .queued
                try dependencies.store.record(items[index])
            default:
                break
            }
            if items[index].state == .retryWait { retryIndices.insert(index) }
            counts[items[index].state, default: 0] += 1
        }

        // A fresh engine means a fresh process: whatever was running (or waiting for the app to
        // come back) was interrupted by termination.
        if job.status == .running || job.status == .paused(.appInBackground) || job.status == .paused(.unexpectedResponse) {
            job.status = .paused(.interrupted)
            try dependencies.store.updateJob(job)
        }

        deps = dependencies
        logger = dependencies.logger.scoped("engine")
        throttler = Throttler(policy: dependencies.policy)
        self.job = job
        self.items = items
        self.retryIndices = retryIndices
        self.counts = counts
    }

    public static func loadActive(dependencies: CleanupEngineDependencies) throws -> CleanupEngine? {
        guard let persisted = try dependencies.store.loadActiveJob() else { return nil }
        return try CleanupEngine(persisted: persisted, dependencies: dependencies)
    }

    // MARK: Control

    /// Records the user's explicit confirmation for this job.
    public func authorize() throws {
        job.authorizedAt = deps.clock.now
        try deps.store.updateJob(job)
    }

    /// Starts or resumes. `userResolvedIssue` must be true to resume after a pause that
    /// required the user to act (e.g. verifying their account).
    public func start(userResolvedIssue: Bool = false) throws {
        guard job.authorizedAt != nil else { throw CleanupEngineError.notAuthorized }
        let wasReady: Bool
        switch job.status {
        case .running:
            throw CleanupEngineError.alreadyRunning
        case .completed, .cancelled:
            throw CleanupEngineError.finished
        case .ready:
            wasReady = true
        case let .paused(reason):
            if reason.requiresUserAction && !userResolvedIssue {
                throw CleanupEngineError.needsUserAction(reason)
            }
            if let until = job.resumeNotBefore, until > deps.clock.now {
                throw CleanupEngineError.coolingDown(until: until)
            }
            wasReady = false
        }

        job.status = .running
        job.resumeNotBefore = nil
        try deps.store.updateJob(job)
        throttler.beginNewRun()
        consecutiveFailures = 0
        estimator.beginSegment(at: deps.clock.now)

        if wasReady {
            let scope: AnalyticsEvent.ScopeKind
            switch job.request.scope {
            case .everything: scope = .everything
            case let .conversations(ids): scope = ids.count == 1 ? .single : .selected
            }
            deps.analytics.track(.cleanupStarted(
                scope: scope,
                size: .init(count: job.itemCount),
                usesFilters: job.request.filter.isAdvanced
            ))
        } else {
            deps.analytics.track(.cleanupResumed)
        }
        logger.info("run started")
        broadcast()

        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func pause() {
        pause(reason: .user)
    }

    /// Called when the app leaves the foreground. iOS may suspend us at any moment, so we
    /// stop scheduling new requests instead of pretending to keep working in the background.
    public func suspendForBackground() {
        pause(reason: .appInBackground)
    }

    /// Resumes only if the pause was caused by backgrounding.
    public func resumeAfterBackground() throws {
        guard job.status == .paused(.appInBackground) else { return }
        try start()
    }

    public func cancel() {
        guard !job.status.isFinished else { return }
        let wasRunning = job.status == .running
        job.status = .cancelled
        job.resumeNotBefore = nil
        do {
            try deps.store.recordCancelPending()
            try deps.store.updateJob(job)
        } catch {
            logger.error("cancel persistence failed: \(error.safeDescription)")
        }
        for index in items.indices where items[index].state.isPending {
            setState(index, .cancelled)
            items[index].nextAttemptAt = nil
        }
        retryIndices.removeAll()
        if wasRunning { runTask?.cancel() }
        estimator.endSegment()
        deps.analytics.track(.cleanupCancelled)
        logger.info("job cancelled")
        broadcast()
    }

    /// Waits until the current run loop exits (paused, completed, cancelled).
    public func waitUntilStopped() async {
        await runTask?.value
    }

    // MARK: Observation

    public func progress() -> CleanupProgress {
        let now = deps.clock.now
        var resumeAt = job.resumeNotBefore
        if job.status == .running, let blocked = throttler.blockedUntil, blocked > now {
            resumeAt = blocked
        }
        let remaining = items.count - terminalCount
        return CleanupProgress(
            jobID: job.id,
            status: job.status,
            total: items.count,
            completed: counts[.completed, default: 0],
            skipped: counts[.skipped, default: 0],
            failed: counts[.failed, default: 0],
            cancelled: counts[.cancelled, default: 0],
            estimatedSecondsRemaining: estimator.estimatedSeconds(remaining: remaining),
            resumeNotBefore: resumeAt
        )
    }

    public func updates() -> AsyncStream<CleanupProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CleanupProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(progress())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public func itemsSnapshot() -> [CleanupItem] { items }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func broadcast() {
        let snapshot = progress()
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    // MARK: Run loop

    private func runLoop() async {
        while job.status == .running {
            guard let index = nextIndex() else {
                finish()
                return
            }
            let now = deps.clock.now
            var wait = throttler.delayBeforeNextRequest(now: now, random: deps.random)
            if let nextAttempt = items[index].nextAttemptAt {
                wait = max(wait, nextAttempt.timeIntervalSince(now))
            }
            if wait > 0 {
                broadcast()
                do {
                    try await deps.clock.sleep(for: wait)
                } catch {
                    return
                }
                guard job.status == .running else { return }
            }
            await process(index)
            broadcast()
        }
    }

    /// Deterministic order: retries that are due, then the queue in order, then the
    /// earliest scheduled retry.
    private func nextIndex() -> Int? {
        let now = deps.clock.now
        let due = retryIndices.filter { (items[$0].nextAttemptAt ?? .distantPast) <= now }
        if let first = due.min() { return first }

        while queueCursor < items.count && items[queueCursor].state != .queued {
            queueCursor += 1
        }
        if queueCursor < items.count { return queueCursor }

        return retryIndices.min { lhs, rhs in
            (items[lhs].nextAttemptAt ?? .distantPast, lhs) < (items[rhs].nextAttemptAt ?? .distantPast, rhs)
        }
    }

    private func process(_ index: Int) async {
        let target = CleanupTarget(item: items[index])

        guard items[index].authorID == job.ownerID else {
            logger.warning("skipping item not authored by owner")
            transition(index, to: .skipped)
            return
        }

        if items[index].needsReconcile {
            await reconcile(index, target: target)
            return
        }

        guard items[index].attempts < deps.policy.maxAttemptsPerItem else {
            transition(index, to: .failed)
            return
        }

        // Persist intent before the destructive call. If we can't, we don't send it.
        items[index].attempts += 1
        items[index].nextAttemptAt = nil
        guard transition(index, to: .processing) else { return }

        throttler.recordRequest(at: deps.clock.now)
        let unsender = deps.unsender
        // Unstructured so pausing can't cancel a request mid-flight and leave its outcome unknown.
        let result = await Task { try await unsender.unsend(target) }.result
        guard items[index].state == .processing else { return }

        switch result {
        case .success(.unsent), .success(.alreadyGone):
            markCompleted(index)
        case .success(.notOwned):
            consecutiveFailures = 0
            transition(index, to: .skipped)
        case let .failure(error):
            handleFailure(index, error: error, destructive: true)
        }
    }

    private func reconcile(_ index: Int, target: CleanupTarget) async {
        throttler.recordRequest(at: deps.clock.now)
        let unsender = deps.unsender
        let result = await Task { try await unsender.presence(of: target) }.result
        guard !items[index].state.isTerminal else { return }

        switch result {
        case .success(.gone):
            items[index].needsReconcile = false
            markCompleted(index)
        case .success(.notOwned):
            items[index].needsReconcile = false
            transition(index, to: .skipped)
        case .success(.present):
            // Confirmed not applied: safe to try the unsend again on the next turn. This doesn't
            // reset the failure streak; only a completed unsend counts as progress.
            throttler.recordSuccess()
            items[index].needsReconcile = false
            items[index].nextAttemptAt = nil
            transition(index, to: job.status == .cancelled ? .cancelled : .retryWait)
        case let .failure(error):
            handleFailure(index, error: error, destructive: false)
        }
    }

    private func markCompleted(_ index: Int) {
        consecutiveFailures = 0
        throttler.recordSuccess()
        items[index].nextAttemptAt = nil
        guard transition(index, to: .completed) else { return }
        do {
            try deps.store.addToLedger([items[index].ref.key])
        } catch {
            logger.error("ledger write failed: \(error.safeDescription)")
        }
        let item = items[index]
        try? deps.history?.append(CleanupHistoryEntry(
            key: item.ref.key,
            conversationID: item.ref.conversationID.rawValue,
            kind: item.kind,
            sentAt: item.sentAt,
            cleanedAt: deps.clock.now
        ))
    }

    private func handleFailure(_ index: Int, error: Error, destructive: Bool) {
        let failure = (error as? IntegrationError) ?? .transportFailure(requestMayHaveBeenApplied: true)
        logger.warning("request failed: \(failure.caseName)")
        let now = deps.clock.now

        // The user cancelled while this request was in flight: nothing more gets scheduled.
        if job.status == .cancelled {
            items[index].nextAttemptAt = nil
            transition(index, to: .cancelled)
            return
        }

        /// The server refused or the request never left: the attempt doesn't count.
        func refundAttempt() {
            if destructive { items[index].attempts = max(0, items[index].attempts - 1) }
        }

        switch failure {
        case let .rateLimited(retryAfter):
            refundAttempt()
            let cooldown = throttler.recordRateLimit(at: now, retryAfter: retryAfter, random: deps.random)
            items[index].nextAttemptAt = now.addingTimeInterval(cooldown)
            transition(index, to: .retryWait)
            if throttler.shouldStopForRateLimits {
                stop(.rateLimited, resumeNotBefore: throttler.blockedUntil)
            }
            return

        case .sessionExpired:
            refundAttempt()
            items[index].nextAttemptAt = nil
            transition(index, to: .retryWait)
            stop(.sessionExpired)
            return

        case .verificationRequired:
            refundAttempt()
            items[index].nextAttemptAt = nil
            transition(index, to: .retryWait)
            stop(.verificationRequired)
            return

        case .unavailable:
            refundAttempt()
            items[index].nextAttemptAt = nil
            transition(index, to: .retryWait)
            stop(.integrationUnavailable)
            return

        case .offline:
            refundAttempt()
            items[index].nextAttemptAt = nil
            transition(index, to: .retryWait)
            stop(.offline)
            return

        case .unexpectedResponse:
            items[index].needsReconcile = false
            items[index].nextAttemptAt = nil
            transition(index, to: .failed)
            return

        case let .transportFailure(mayHaveBeenApplied):
            if destructive && mayHaveBeenApplied { items[index].needsReconcile = true }
            if !destructive { items[index].attempts += 1 }

        case .serverUnavailable:
            if destructive { items[index].needsReconcile = true }
            if !destructive { items[index].attempts += 1 }
        }

        consecutiveFailures += 1
        if items[index].attempts >= deps.policy.maxAttemptsPerItem {
            items[index].nextAttemptAt = nil
            transition(index, to: .failed)
        } else {
            let delay = Backoff.delay(forAttempt: max(1, items[index].attempts), policy: deps.policy, random: deps.random)
            items[index].nextAttemptAt = now.addingTimeInterval(delay)
            transition(index, to: .retryWait)
        }

        if consecutiveFailures >= deps.policy.maxConsecutiveFailures {
            stop(.repeatedFailures)
        }
    }

    // MARK: State

    private var terminalCount: Int {
        counts[.completed, default: 0] + counts[.skipped, default: 0]
            + counts[.failed, default: 0] + counts[.cancelled, default: 0]
    }

    /// Applies and persists a state change. Returns false (and pauses the job) if the change
    /// couldn't be persisted.
    @discardableResult
    private func transition(_ index: Int, to state: CleanupItemState) -> Bool {
        setState(index, state)
        if state.isTerminal { estimator.recordItem(at: deps.clock.now) }
        do {
            try deps.store.record(items[index])
            return true
        } catch {
            logger.error("progress write failed: \(error.safeDescription)")
            if state == .processing {
                // Not sent yet: roll back so the in-memory state matches what's on disk.
                items[index].attempts = max(0, items[index].attempts - 1)
                setState(index, .queued)
                if index < queueCursor { queueCursor = index }
            }
            stop(.storageFailure)
            return false
        }
    }

    private func setState(_ index: Int, _ state: CleanupItemState) {
        let old = items[index].state
        guard old != state else { return }
        counts[old, default: 0] -= 1
        counts[state, default: 0] += 1
        items[index].state = state
        if state == .retryWait { retryIndices.insert(index) } else { retryIndices.remove(index) }
    }

    private func stop(_ reason: PauseReason, resumeNotBefore: Date? = nil) {
        guard job.status == .running else { return }
        job.status = .paused(reason)
        job.resumeNotBefore = resumeNotBefore
        persistJob()
        estimator.endSegment()
        deps.analytics.track(.cleanupPaused(reason: .init(reason)))
        logger.info("paused: \(reason.rawValue)")
        broadcast()
    }

    private func pause(reason: PauseReason) {
        guard job.status == .running else { return }
        stop(reason)
        runTask?.cancel()
    }

    private func finish() {
        job.status = .completed
        job.resumeNotBefore = nil
        persistJob()
        estimator.endSegment()
        deps.analytics.track(.cleanupCompleted(size: .init(count: counts[.completed, default: 0])))
        logger.info("job completed")
        broadcast()
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    private func persistJob() {
        do {
            try deps.store.updateJob(job)
        } catch {
            logger.error("job write failed: \(error.safeDescription)")
        }
    }
}
