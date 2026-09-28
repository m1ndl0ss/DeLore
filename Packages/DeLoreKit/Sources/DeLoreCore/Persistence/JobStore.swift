import Foundation

public struct PersistedJob: Sendable {
    public let job: CleanupJob
    public let items: [CleanupItem]

    public init(job: CleanupJob, items: [CleanupItem]) {
        self.job = job
        self.items = items
    }
}

public enum JobStoreError: Error, Equatable, Sendable {
    case noActiveJob
    case corrupted
    case ioFailure
}

/// Persistence for the (single) active cleanup job and the ledger of cleaned messages.
///
/// Item records are absolute states, never deltas, so replaying a record twice is harmless.
/// That property is what keeps the store consistent across crashes and compaction.
public protocol JobStore: AnyObject, Sendable {
    /// Starts a new job, discarding any previous active job.
    func createJob(_ job: CleanupJob) throws
    func appendItems(_ items: [CleanupItem]) throws
    func updateJob(_ job: CleanupJob) throws
    func record(_ item: CleanupItem) throws
    /// Marks every pending item as cancelled in a single record.
    func recordCancelPending() throws
    func loadActiveJob() throws -> PersistedJob?
    func discardActiveJob() throws

    func loadLedger() throws -> Set<String>
    func addToLedger(_ keys: [String]) throws

    /// Removes everything this store ever wrote.
    func wipe() throws
}

/// Applies a cancel-pending record to items.
func applyCancelPending(_ items: inout [CleanupItem]) {
    for index in items.indices where items[index].state.isPending {
        items[index].state = .cancelled
        items[index].nextAttemptAt = nil
    }
}

public final class InMemoryJobStore: JobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var job: CleanupJob?
    private var items: [CleanupItem] = []
    private var ledger: Set<String> = []
    public private(set) var recordCount = 0
    /// Test hook: throw on the n-th `record` call.
    public var failOnRecord: Int?

    public init() {}

    public func createJob(_ job: CleanupJob) throws {
        lock.withLock {
            self.job = job
            items = []
        }
    }

    public func appendItems(_ newItems: [CleanupItem]) throws {
        lock.withLock { items.append(contentsOf: newItems) }
    }

    public func updateJob(_ job: CleanupJob) throws {
        lock.withLock { self.job = job }
    }

    public func record(_ item: CleanupItem) throws {
        try lock.withLock {
            recordCount += 1
            if let failOnRecord, recordCount == failOnRecord { throw JobStoreError.ioFailure }
            guard items.indices.contains(item.index) else { throw JobStoreError.corrupted }
            items[item.index] = item
        }
    }

    public func recordCancelPending() throws {
        lock.withLock { applyCancelPending(&items) }
    }

    public func loadActiveJob() throws -> PersistedJob? {
        lock.withLock { job.map { PersistedJob(job: $0, items: items) } }
    }

    public func discardActiveJob() throws {
        lock.withLock {
            job = nil
            items = []
        }
    }

    public func loadLedger() throws -> Set<String> {
        lock.withLock { ledger }
    }

    public func addToLedger(_ keys: [String]) throws {
        lock.withLock { ledger.formUnion(keys) }
    }

    public func wipe() throws {
        lock.withLock {
            job = nil
            items = []
            ledger = []
        }
    }
}
