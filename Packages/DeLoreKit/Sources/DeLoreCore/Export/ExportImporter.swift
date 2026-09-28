import Foundation

public enum OwnerResolution: Equatable, Sendable {
    /// Exactly one participant appears in every conversation: that's the account owner.
    case resolved(name: String)
    /// We can't tell reliably; the user picks from these candidates.
    case needsChoice(candidates: [String])
    case noMessages
}

public enum ExportImportError: Error, Equatable, Sendable {
    case noMessagesFound
    case unreadable
}

/// Turns an export into the local, content-free library.
public struct ExportImporter: Sendable {
    private let archive: ExportArchive
    private let library: LocalLibraryStore

    public init(archive: ExportArchive, library: LocalLibraryStore) {
        self.archive = archive
        self.library = library
    }

    private struct ThreadFiles {
        let thread: String
        var files: [(number: Int, path: String)]
    }

    private func threadFiles() throws -> [ThreadFiles] {
        var byThread: [String: ThreadFiles] = [:]
        for path in try archive.entryPaths() {
            guard let location = InstagramExportFormat.threadLocation(of: path) else { continue }
            byThread[location.thread, default: ThreadFiles(thread: location.thread, files: [])]
                .files.append((location.fileNumber, path))
        }
        return byThread.values
            .map { ThreadFiles(thread: $0.thread, files: $0.files.sorted { $0.number < $1.number }) }
            .sorted { $0.thread < $1.thread }
    }

    /// First pass: participant names only, to figure out who the account owner is.
    public func resolveOwner() async throws -> OwnerResolution {
        let threads = try threadFiles()
        guard !threads.isEmpty else { return .noMessages }
        let decoder = JSONDecoder()
        var threadsContaining: [String: Int] = [:]

        for thread in threads {
            try Task.checkCancellation()
            guard let first = thread.files.first else { continue }
            let data = try archive.contents(of: first.path)
            guard let file = try? decoder.decode(InstagramExportFormat.ParticipantsOnly.self, from: data) else { continue }
            let names = Set((file.participants ?? []).compactMap(\.name).map(InstagramExportFormat.repairingMojibake))
            for name in names { threadsContaining[name, default: 0] += 1 }
        }

        let ranked = threadsContaining.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let inEveryThread = ranked.filter { $0.value == threads.count }.map(\.key)
        if threads.count >= 2, inEveryThread.count == 1, let owner = inEveryThread.first {
            return .resolved(name: owner)
        }
        return .needsChoice(candidates: Array(ranked.prefix(6).map(\.key)))
    }

    /// Second pass: keeps only messages the owner sent, as id/timestamp/kind. Everything
    /// else is reduced to counts.
    public func importLibrary(ownerName: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> LibraryOverview {
        let threads = try threadFiles()
        guard !threads.isEmpty else { throw ExportImportError.noMessagesFound }
        let decoder = JSONDecoder()
        let ownerID = InstagramExportFormat.participantID(forName: ownerName)
        let writer = try library.beginImport(account: AccountIdentity(ownerID: ownerID, displayName: ownerName))

        for (threadIndex, thread) in threads.enumerated() {
            try Task.checkCancellation()
            var title: String?
            var participantNames: [String] = []
            var ownerMessages: [(timestamp: Int64, kind: MessageKind)] = []
            var received = 0

            for file in thread.files {
                let data = try archive.contents(of: file.path)
                guard let decoded = try? decoder.decode(InstagramExportFormat.ThreadFile.self, from: data) else { continue }
                if title == nil { title = decoded.title.map(InstagramExportFormat.repairingMojibake) }
                if participantNames.isEmpty {
                    participantNames = (decoded.participants ?? []).compactMap(\.name).map(InstagramExportFormat.repairingMojibake)
                }
                for message in decoded.messages ?? [] {
                    guard let sender = message.senderName.map(InstagramExportFormat.repairingMojibake),
                          let timestamp = message.timestampMs else { continue }
                    if sender == ownerName {
                        if !message.isSystemEntry { ownerMessages.append((timestamp, message.kind)) }
                    } else {
                        received += 1
                    }
                }
            }

            // If the owner isn't listed, or someone else shares their name, we can't attribute
            // messages safely, so the conversation is never offered for cleanup.
            let ownerOccurrences = participantNames.filter { $0 == ownerName }.count
            let ambiguous = ownerOccurrences != 1

            // Files are newest-first; a stable sort keeps same-millisecond order deterministic.
            let ordered = ownerMessages.enumerated()
                .sorted { ($0.element.timestamp, -$0.offset) < ($1.element.timestamp, -$1.offset) }
                .map(\.element)

            let conversationID = ConversationID(thread.thread)
            var messages: [DiscoveredMessage] = []
            messages.reserveCapacity(ordered.count)
            var ordinalForTimestamp: [Int64: Int] = [:]
            var byKind: [MessageKind: Int] = [:]
            for entry in ordered {
                let ordinal = ordinalForTimestamp[entry.timestamp, default: 0]
                ordinalForTimestamp[entry.timestamp] = ordinal + 1
                byKind[entry.kind, default: 0] += 1
                messages.append(DiscoveredMessage(
                    ref: MessageRef(conversationID: conversationID, messageID: "\(entry.timestamp)-\(ordinal)"),
                    authorID: ownerID,
                    sentAt: Date(timeIntervalSince1970: Double(entry.timestamp) / 1000),
                    kind: entry.kind
                ))
            }

            let others = participantNames.filter { $0 != ownerName }
            let displayTitle = title ?? (others.isEmpty ? "Chat" : others.joined(separator: ", "))
            let summary = ConversationSummary(
                id: conversationID,
                title: displayTitle,
                sentByOwner: ambiguous ? 0 : messages.count,
                receivedFromOthers: received,
                firstSentAt: messages.first?.sentAt,
                lastSentAt: messages.last?.sentAt,
                sentByKind: ambiguous ? [:] : byKind,
                ownershipAmbiguous: ambiguous
            )
            try writer.add(summary: summary, messages: ambiguous ? [] : messages)
            onProgress?(Double(threadIndex + 1) / Double(threads.count))
        }

        let overview = try writer.commit()
        guard overview.sentByOwner + overview.receivedFromOthers > 0 else { throw ExportImportError.noMessagesFound }
        return overview
    }
}
