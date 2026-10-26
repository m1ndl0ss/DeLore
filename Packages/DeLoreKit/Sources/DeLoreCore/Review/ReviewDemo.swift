import Foundation

/// Fake inbox for App Review and first-run try-out. Never talks to Instagram.
public enum ReviewDemo: Sendable {
    public static let account = AccountIdentity(
        ownerID: ParticipantID("demo:you"),
        displayName: "you"
    )

    public static let chats: [(id: String, title: String, count: Int)] = [
        ("demo-bestie", "bestie", 125),
        ("demo-group", "the group chat", 96),
        ("demo-ex", "the ex", 72),
        ("demo-roommates", "roommates", 48),
        ("demo-gym", "gym crew", 36),
        ("demo-mom", "mom", 24),
    ]

    public static func seed(into library: LocalLibraryStore) throws {
        let writer = try library.beginImport(account: account)
        let kinds: [MessageKind] = [.text, .text, .text, .media, .link, .voice]
        let base = Date(timeIntervalSince1970: 1_560_000_000)
        for chat in chats {
            let id = ConversationID(chat.id)
            var messages: [DiscoveredMessage] = []
            messages.reserveCapacity(chat.count)
            var byKind: [MessageKind: Int] = [:]
            for index in 0..<chat.count {
                let kind = kinds[index % kinds.count]
                byKind[kind, default: 0] += 1
                messages.append(
                    DiscoveredMessage(
                        ref: MessageRef(conversationID: id, messageID: "demo-\(chat.id)-\(index)"),
                        authorID: account.ownerID,
                        sentAt: base.addingTimeInterval(Double(index) * 90),
                        kind: kind
                    )
                )
            }
            try writer.add(
                summary: ConversationSummary(
                    id: id,
                    title: chat.title,
                    sentByOwner: chat.count,
                    receivedFromOthers: chat.count / 3,
                    firstSentAt: messages.first?.sentAt,
                    lastSentAt: messages.last?.sentAt,
                    sentByKind: byKind,
                    messagesLoaded: true
                ),
                messages: messages
            )
        }
        _ = try writer.commit()
    }
}

/// Local unsend used while the sample inbox is on. Marks items gone in memory only.
public final class ReviewDemoUnsendService: UnsendService, @unchecked Sendable {
    private let lock = NSLock()
    private var gone = Set<String>()

    public init() {}

    public func unsend(_ target: CleanupTarget) async throws -> UnsendOutcome {
        lock.withLock {
            if gone.contains(target.ref.key) { return .alreadyGone }
            gone.insert(target.ref.key)
            return .unsent
        }
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        lock.withLock { gone.contains(target.ref.key) ? .gone : .present }
    }
}
