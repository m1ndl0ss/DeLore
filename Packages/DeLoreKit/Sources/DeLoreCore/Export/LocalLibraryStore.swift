import Foundation

/// The on-device library produced by an import: conversation summaries plus, per
/// conversation, the ids/timestamps/kinds of messages the owner sent. No message content.
///
/// Also serves as the `MessageSource` for queue building, reading one conversation at a time.
public final class LocalLibraryStore: MessageSource, @unchecked Sendable {
    private struct Manifest: Codable {
        var account: AccountIdentity
        var conversations: [ConversationSummary]
        /// Conversation id → index file name. File names never contain ids or names.
        var files: [String: String]
        var importedAt: Date
    }

    private struct IndexLine: Codable {
        let m: String
        let t: Double
        let k: MessageKind
    }

    private let root: URL
    private let lock = NSLock()
    private var cached: Manifest?

    /// Directory creation is retried by every write, so a transient failure here isn't fatal.
    public init(root: URL) {
        self.root = root
        try? ProtectedFiles.prepareDirectory(root)
    }

    private var manifestURL: URL { root.appendingPathComponent("library.json") }
    private func indexDirectory(in base: URL) -> URL { base.appendingPathComponent("index", isDirectory: true) }

    public var hasLibrary: Bool { (try? loadManifest()) != nil }

    public var importedAt: Date? { (try? loadManifest())?.importedAt }

    private func loadManifest() throws -> Manifest {
        try lock.withLock { try loadManifestUnlocked() }
    }

    private func loadManifestUnlocked() throws -> Manifest {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: manifestURL) else { throw JobStoreError.noActiveJob }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        cached = manifest
        return manifest
    }

    public func overview() throws -> LibraryOverview {
        LibraryOverview(conversations: try loadManifest().conversations)
    }

    /// Summaries recomputed without messages already cleaned (keys from the ledger), so the
    /// counts people see match what's actually left.
    public func overview(excluding cleaned: Set<String>) async throws -> LibraryOverview {
        let manifest = try loadManifest()
        guard !cleaned.isEmpty else { return LibraryOverview(conversations: manifest.conversations) }
        var adjusted: [ConversationSummary] = []
        adjusted.reserveCapacity(manifest.conversations.count)
        for summary in manifest.conversations {
            guard summary.isCleanable else {
                adjusted.append(summary)
                continue
            }
            var sent = 0
            var byKind: [MessageKind: Int] = [:]
            var first: Date?
            var last: Date?
            for try await page in messagePages(in: summary.id, pageSize: 500) {
                for message in page where !cleaned.contains(message.ref.key) {
                    sent += 1
                    byKind[message.kind, default: 0] += 1
                    first = first ?? message.sentAt
                    last = message.sentAt
                }
            }
            adjusted.append(ConversationSummary(
                id: summary.id,
                title: summary.title,
                sentByOwner: sent,
                receivedFromOthers: summary.receivedFromOthers,
                firstSentAt: first,
                lastSentAt: last,
                sentByKind: byKind,
                ownershipAmbiguous: summary.ownershipAmbiguous,
                messagesLoaded: summary.messagesLoaded
            ))
        }
        return LibraryOverview(conversations: adjusted)
    }

    // MARK: MessageSource

    public func account() async throws -> AccountIdentity {
        try loadManifest().account
    }

    public func conversations() async throws -> [ConversationSummary] {
        try loadManifest().conversations
    }

    public func messagePages(in conversation: ConversationID, pageSize: Int) -> AsyncThrowingStream<[DiscoveredMessage], Error> {
        AsyncThrowingStream { continuation in
            do {
                let manifest = try loadManifest()
                guard let fileName = manifest.files[conversation.rawValue] else {
                    continuation.finish()
                    return
                }
                let url = indexDirectory(in: root).appendingPathComponent(fileName)
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let decoder = JSONDecoder()
                var page: [DiscoveredMessage] = []
                page.reserveCapacity(pageSize)
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    let entry = try decoder.decode(IndexLine.self, from: Data(line))
                    page.append(DiscoveredMessage(
                        ref: MessageRef(conversationID: conversation, messageID: entry.m),
                        authorID: manifest.account.ownerID,
                        sentAt: Date(timeIntervalSince1970: entry.t),
                        kind: entry.k
                    ))
                    if page.count >= pageSize {
                        continuation.yield(page)
                        page.removeAll(keepingCapacity: true)
                    }
                }
                if !page.isEmpty { continuation.yield(page) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: Import

    public final class ImportWriter: @unchecked Sendable {
        private let store: LocalLibraryStore
        private let staging: URL
        private var manifest: Manifest
        private let encoder = JSONEncoder()

        fileprivate init(store: LocalLibraryStore, staging: URL, account: AccountIdentity) {
            self.store = store
            self.staging = staging
            manifest = Manifest(account: account, conversations: [], files: [:], importedAt: Date())
        }

        public func add(summary: ConversationSummary, messages: [DiscoveredMessage]) throws {
            let fileName = "c\(manifest.conversations.count).jsonl"
            var data = Data()
            for message in messages {
                data.append(try encoder.encode(IndexLine(m: message.ref.messageID, t: message.sentAt.timeIntervalSince1970, k: message.kind)))
                data.append(0x0A)
            }
            try ProtectedFiles.write(data, to: store.indexDirectory(in: staging).appendingPathComponent(fileName))
            manifest.conversations.append(summary)
            manifest.files[summary.id.rawValue] = fileName
        }

        public func addCopy(summary: ConversationSummary, source: URL) throws {
            let fileName = "c\(manifest.conversations.count).jsonl"
            let dest = store.indexDirectory(in: staging).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: dest)
            } else {
                try ProtectedFiles.write(Data(), to: dest)
            }
            manifest.conversations.append(summary)
            manifest.files[summary.id.rawValue] = fileName
        }

        /// Atomically replaces the previous library with this import.
        public func commit() throws -> LibraryOverview {
            try ProtectedFiles.write(encoder.encode(manifest), to: staging.appendingPathComponent("library.json"))
            try store.replace(with: staging, manifest: manifest)
            return LibraryOverview(conversations: manifest.conversations)
        }
    }

    public func beginImport(account: AccountIdentity) throws -> ImportWriter {
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".staging", isDirectory: true)
        try ProtectedFiles.removeItemIfPresent(staging)
        try ProtectedFiles.prepareDirectory(staging)
        try ProtectedFiles.prepareDirectory(indexDirectory(in: staging))
        return ImportWriter(store: self, staging: staging, account: account)
    }

    public func mergeListing(account: AccountIdentity, stubs: [ConversationSummary]) throws -> LibraryOverview {
        let existing = try? loadManifest()
        let writer = try beginImport(account: account)
        for stub in stubs {
            let prior = existing?.conversations.first { $0.id == stub.id }
            if let prior, prior.messagesLoaded, let fileName = existing?.files[stub.id.rawValue] {
                let source = indexDirectory(in: root).appendingPathComponent(fileName)
                try writer.addCopy(summary: ConversationSummary(
                    id: prior.id,
                    title: stub.title,
                    sentByOwner: prior.sentByOwner,
                    receivedFromOthers: prior.receivedFromOthers,
                    firstSentAt: prior.firstSentAt,
                    lastSentAt: prior.lastSentAt,
                    sentByKind: prior.sentByKind,
                    ownershipAmbiguous: prior.ownershipAmbiguous,
                    messagesLoaded: prior.messagesLoaded
                ), source: source)
            } else {
                try writer.add(summary: stub, messages: [])
            }
        }
        return try writer.commit()
    }

    public func upsertLoaded(summary: ConversationSummary, messages: [DiscoveredMessage]) throws -> LibraryOverview {
        try lock.withLock {
            let current: Manifest
            if let cached {
                current = cached
            } else {
                guard let data = try? Data(contentsOf: manifestURL) else { throw JobStoreError.noActiveJob }
                current = try JSONDecoder().decode(Manifest.self, from: data)
            }
            let loaded = ConversationSummary(
                id: summary.id,
                title: summary.title,
                sentByOwner: summary.sentByOwner,
                receivedFromOthers: summary.receivedFromOthers,
                firstSentAt: summary.firstSentAt,
                lastSentAt: summary.lastSentAt,
                sentByKind: summary.sentByKind,
                ownershipAmbiguous: summary.ownershipAmbiguous,
                messagesLoaded: true
            )
            let fileName = current.files[loaded.id.rawValue] ?? "c\(current.conversations.count).jsonl"
            var data = Data()
            let encoder = JSONEncoder()
            for message in messages {
                data.append(try encoder.encode(IndexLine(m: message.ref.messageID, t: message.sentAt.timeIntervalSince1970, k: message.kind)))
                data.append(0x0A)
            }
            try ProtectedFiles.prepareDirectory(indexDirectory(in: root))
            try ProtectedFiles.write(data, to: indexDirectory(in: root).appendingPathComponent(fileName))
            var conversations = current.conversations
            if let index = conversations.firstIndex(where: { $0.id == loaded.id }) {
                conversations[index] = loaded
            } else {
                conversations.append(loaded)
            }
            var updated = current
            updated.conversations = conversations
            updated.files[loaded.id.rawValue] = fileName
            try ProtectedFiles.write(JSONEncoder().encode(updated), to: manifestURL)
            cached = updated
            return LibraryOverview(conversations: updated.conversations)
        }
    }

    private func replace(with staging: URL, manifest: Manifest) throws {
        try lock.withLock {
            let fileManager = FileManager.default
            try ProtectedFiles.removeItemIfPresent(root)
            try fileManager.moveItem(at: staging, to: root)
            try ProtectedFiles.prepareDirectory(root)
            cached = manifest
        }
    }

    /// Drop cleaned messages from the on-device index so counts stay honest after cancel.
    public func excludeCleaned(_ cleaned: Set<String>) throws -> LibraryOverview {
        try lock.withLock {
            let current = try loadManifestUnlocked()
            guard !cleaned.isEmpty else {
                return LibraryOverview(conversations: current.conversations)
            }
            var conversations: [ConversationSummary] = []
            conversations.reserveCapacity(current.conversations.count)
            for summary in current.conversations {
                guard summary.messagesLoaded, let fileName = current.files[summary.id.rawValue] else {
                    conversations.append(summary)
                    continue
                }
                let url = indexDirectory(in: root).appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: url) else {
                    conversations.append(summary)
                    continue
                }
                let decoder = JSONDecoder()
                let encoder = JSONEncoder()
                var kept = Data()
                var sent = 0
                var byKind: [MessageKind: Int] = [:]
                var first: Date?
                var last: Date?
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    guard let entry = try? decoder.decode(IndexLine.self, from: Data(line)) else { continue }
                    let key = summary.id.rawValue + "|" + entry.m
                    if cleaned.contains(key) { continue }
                    kept.append(Data(line))
                    kept.append(0x0A)
                    sent += 1
                    byKind[entry.k, default: 0] += 1
                    let date = Date(timeIntervalSince1970: entry.t)
                    first = first ?? date
                    last = date
                }
                try ProtectedFiles.write(kept, to: url)
                conversations.append(ConversationSummary(
                    id: summary.id,
                    title: summary.title,
                    sentByOwner: sent,
                    receivedFromOthers: summary.receivedFromOthers,
                    firstSentAt: first,
                    lastSentAt: last,
                    sentByKind: byKind,
                    ownershipAmbiguous: summary.ownershipAmbiguous,
                    messagesLoaded: summary.messagesLoaded
                ))
            }
            var updated = current
            updated.conversations = conversations
            try ProtectedFiles.write(JSONEncoder().encode(updated), to: manifestURL)
            cached = updated
            return LibraryOverview(conversations: conversations)
        }
    }

    /// Replaces the stored summaries (e.g. after a cleanup lowers counts).
    public func updateConversations(_ transform: ([ConversationSummary]) -> [ConversationSummary]) throws {
        var manifest = try loadManifest()
        manifest.conversations = transform(manifest.conversations)
        try ProtectedFiles.write(JSONEncoder().encode(manifest), to: manifestURL)
        lock.withLock { cached = manifest }
    }

    public func wipe() throws {
        try lock.withLock {
            cached = nil
            try ProtectedFiles.removeItemIfPresent(root)
            try ProtectedFiles.removeItemIfPresent(
                root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".staging", isDirectory: true)
            )
            try ProtectedFiles.prepareDirectory(root)
        }
    }
}
