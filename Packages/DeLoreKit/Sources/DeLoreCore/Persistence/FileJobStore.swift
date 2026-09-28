import Foundation

/// File-backed job store.
///
/// Layout under `root`:
/// - `active/job.json`       job metadata, replaced atomically
/// - `active/items.jsonl`    item snapshot, one item per line
/// - `active/journal.jsonl`  append-only absolute item states since the last snapshot
/// - `ledger.jsonl`          keys of messages already cleaned, across jobs
///
/// A torn final line (crash mid-append) is ignored on load. Compaction writes a fresh snapshot
/// atomically before deleting the journal; if we crash in between, replaying the old journal
/// onto the new snapshot yields the same state because records are absolute.
public final class FileJobStore: JobStore, @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let compactionThreshold: Int
    private var journalLines = 0

    public init(root: URL, compactionThreshold: Int = 2_000) throws {
        self.root = root
        self.compactionThreshold = compactionThreshold
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try ProtectedFiles.prepareDirectory(root)
    }

    private var activeDirectory: URL { root.appendingPathComponent("active", isDirectory: true) }
    private var jobURL: URL { activeDirectory.appendingPathComponent("job.json") }
    private var itemsURL: URL { activeDirectory.appendingPathComponent("items.jsonl") }
    private var journalURL: URL { activeDirectory.appendingPathComponent("journal.jsonl") }
    private var ledgerURL: URL { root.appendingPathComponent("ledger.jsonl") }

    private struct JournalLine: Codable {
        var type: String
        var item: CleanupItem?

        static func item(_ item: CleanupItem) -> JournalLine { JournalLine(type: "i", item: item) }
        static let cancelPending = JournalLine(type: "x", item: nil)
    }

    // MARK: Job

    public func createJob(_ job: CleanupJob) throws {
        try lock.withLock {
            try ProtectedFiles.removeItemIfPresent(activeDirectory)
            try ProtectedFiles.prepareDirectory(activeDirectory)
            try ProtectedFiles.write(Data(), to: itemsURL)
            try ProtectedFiles.write(encoder.encode(job), to: jobURL)
            journalLines = 0
        }
    }

    public func appendItems(_ items: [CleanupItem]) throws {
        guard !items.isEmpty else { return }
        try lock.withLock {
            try ProtectedFiles.append(encodeLines(items), to: itemsURL)
        }
    }

    public func updateJob(_ job: CleanupJob) throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: activeDirectory.path) else { throw JobStoreError.noActiveJob }
            try ProtectedFiles.write(encoder.encode(job), to: jobURL)
        }
    }

    public func record(_ item: CleanupItem) throws {
        try appendJournal(.item(item))
    }

    public func recordCancelPending() throws {
        try appendJournal(.cancelPending)
    }

    private func appendJournal(_ line: JournalLine) throws {
        try lock.withLock {
            var data = try encoder.encode(line)
            data.append(0x0A)
            try ProtectedFiles.append(data, to: journalURL)
            journalLines += 1
            if journalLines >= compactionThreshold {
                try compactLocked()
            }
        }
    }

    public func loadActiveJob() throws -> PersistedJob? {
        try lock.withLock {
            guard let jobData = try? Data(contentsOf: jobURL) else { return nil }
            let job = try decoder.decode(CleanupJob.self, from: jobData)
            var items = try loadItemsLocked()
            let replayed = try replayJournalLocked(into: &items)
            journalLines = replayed
            return PersistedJob(job: job, items: items)
        }
    }

    public func discardActiveJob() throws {
        try lock.withLock {
            try ProtectedFiles.removeItemIfPresent(activeDirectory)
            journalLines = 0
        }
    }

    // MARK: Ledger

    public func loadLedger() throws -> Set<String> {
        lock.withLock {
            guard let data = try? Data(contentsOf: ledgerURL) else { return [] }
            var keys = Set<String>()
            for line in data.split(separator: 0x0A) {
                if let key = String(data: Data(line), encoding: .utf8), !key.isEmpty { keys.insert(key) }
            }
            return keys
        }
    }

    public func addToLedger(_ keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try lock.withLock {
            var data = Data()
            for key in keys where !key.contains("\n") {
                data.append(contentsOf: Array(key.utf8))
                data.append(0x0A)
            }
            try ProtectedFiles.append(data, to: ledgerURL)
        }
    }

    public func wipe() throws {
        try lock.withLock {
            try ProtectedFiles.removeItemIfPresent(root)
            try ProtectedFiles.prepareDirectory(root)
            journalLines = 0
        }
    }

    /// Forces a snapshot. Exposed for tests; normally triggered by the journal size.
    public func compact() throws {
        try lock.withLock { try compactLocked() }
    }

    // MARK: Internals (call with lock held)

    private func encodeLines(_ items: [CleanupItem]) throws -> Data {
        var data = Data()
        for item in items {
            data.append(try encoder.encode(item))
            data.append(0x0A)
        }
        return data
    }

    private func loadItemsLocked() throws -> [CleanupItem] {
        guard let data = try? Data(contentsOf: itemsURL) else { return [] }
        var items: [CleanupItem] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let item = try? decoder.decode(CleanupItem.self, from: Data(line)) else { continue }
            if item.index == items.count {
                items.append(item)
            } else if items.indices.contains(item.index) {
                items[item.index] = item
            } else {
                throw JobStoreError.corrupted
            }
        }
        return items
    }

    private func replayJournalLocked(into items: inout [CleanupItem]) throws -> Int {
        guard let data = try? Data(contentsOf: journalURL) else { return 0 }
        var count = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            // Undecodable lines are torn writes from a crash; the item keeps its previous state.
            guard let record = try? decoder.decode(JournalLine.self, from: Data(line)) else { continue }
            count += 1
            switch record.type {
            case "i":
                if let item = record.item, items.indices.contains(item.index) { items[item.index] = item }
            case "x":
                applyCancelPending(&items)
            default:
                continue
            }
        }
        return count
    }

    private func compactLocked() throws {
        var items = try loadItemsLocked()
        _ = try replayJournalLocked(into: &items)
        try ProtectedFiles.write(encodeLines(items), to: itemsURL)
        try ProtectedFiles.removeItemIfPresent(journalURL)
        journalLines = 0
    }
}
