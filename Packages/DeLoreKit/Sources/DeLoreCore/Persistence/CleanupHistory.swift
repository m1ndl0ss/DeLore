import Foundation

/// One unsent message, with no text. Chat title is resolved at display time.
public struct CleanupHistoryEntry: Hashable, Codable, Sendable {
    public let key: String
    public let conversationID: String
    public let kind: MessageKind
    public let sentAt: Date
    public let cleanedAt: Date

    public init(key: String, conversationID: String, kind: MessageKind, sentAt: Date, cleanedAt: Date) {
        self.key = key
        self.conversationID = conversationID
        self.kind = kind
        self.sentAt = sentAt
        self.cleanedAt = cleanedAt
    }
}

public protocol CleanupHistoryStore: AnyObject, Sendable {
    func append(_ entry: CleanupHistoryEntry) throws
    func load() throws -> [CleanupHistoryEntry]
    func wipe() throws
}

public final class FileCleanupHistoryStore: CleanupHistoryStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) throws {
        try ProtectedFiles.prepareDirectory(root)
        url = root.appendingPathComponent("history.jsonl")
    }

    public func append(_ entry: CleanupHistoryEntry) throws {
        try lock.withLock {
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try ProtectedFiles.append(data, to: url)
        }
    }

    public func load() throws -> [CleanupHistoryEntry] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let raw = try String(contentsOf: url, encoding: .utf8)
            return raw.split(whereSeparator: \.isNewline).compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(CleanupHistoryEntry.self, from: data)
            }
        }
    }

    public func wipe() throws {
        try lock.withLock {
            try ProtectedFiles.removeItemIfPresent(url)
        }
    }
}

public final class InMemoryCleanupHistoryStore: CleanupHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CleanupHistoryEntry] = []

    public init() {}

    public func append(_ entry: CleanupHistoryEntry) throws {
        lock.withLock { entries.append(entry) }
    }

    public func load() throws -> [CleanupHistoryEntry] {
        lock.withLock { entries }
    }

    public func wipe() throws {
        lock.withLock { entries = [] }
    }
}
