import DeLoreCore
import Foundation

/// Deterministic stand-in for Instagram. Messages are generated from a seed on demand, so
/// conversations with hundreds of thousands of messages cost almost no memory.
///
/// Faults can be scripted per unsend call to exercise every engine path. The fake also
/// records any attempt to unsend a message the owner didn't send.
public final class FakeInstagramService: MessageSource, UnsendService, @unchecked Sendable {
    public struct ConversationSpec: Sendable {
        public let id: ConversationID
        public let title: String
        public let messageCount: Int
        /// Percentage (0...100) of messages authored by the owner.
        public let ownerShare: Int
        /// Emits every n-th owner message twice to simulate a source returning duplicates.
        public let duplicateEvery: Int?

        public init(id: String, title: String, messageCount: Int, ownerShare: Int = 50, duplicateEvery: Int? = nil) {
            self.id = ConversationID(id)
            self.title = title
            self.messageCount = messageCount
            self.ownerShare = ownerShare
            self.duplicateEvery = duplicateEvery
        }
    }

    public enum Fault: Sendable, Equatable {
        case rateLimited(retryAfter: TimeInterval?)
        case sessionExpired
        case verificationRequired
        case offline
        /// The unsend is applied, but the response is lost.
        case timeoutAfterApplying
        /// The request times out before being applied.
        case timeoutBeforeApplying
        case serverError
        case unexpected(code: Int)
    }

    public let owner: AccountIdentity
    public let other = ParticipantID("fake:other")
    private let specs: [ConversationSpec]
    private let seed: UInt64
    private let baseDate: Date
    private let latency: TimeInterval

    private let lock = NSLock()
    private var removed = Set<String>()
    private var unsendCounts: [String: Int] = [:]
    private var unsendCallCount = 0
    private var presenceCallCount = 0
    private var scriptedFaults: [Int: Fault] = [:]
    private var scriptedPresenceFaults: [Int: Fault] = [:]
    private var persistentFault: Fault?
    private var foreignUnsendAttempts: [MessageRef] = []
    private var largestPage = 0
    private var pagesServed = 0
    private var onUnsendHook: (@Sendable (Int) async -> Void)?

    public init(
        owner: AccountIdentity = AccountIdentity(ownerID: ParticipantID("fake:owner"), displayName: "you"),
        conversations: [ConversationSpec],
        seed: UInt64 = 42,
        baseDate: Date = Date(timeIntervalSince1970: 1_500_000_000),
        latency: TimeInterval = 0
    ) {
        self.owner = owner
        specs = conversations
        self.seed = seed
        self.baseDate = baseDate
        self.latency = latency
    }

    // MARK: Scripting

    public func scriptFault(_ fault: Fault, onUnsendCall call: Int) {
        lock.withLock { scriptedFaults[call] = fault }
    }

    public func scriptPresenceFault(_ fault: Fault, onPresenceCall call: Int) {
        lock.withLock { scriptedPresenceFaults[call] = fault }
    }

    public func setPersistentFault(_ fault: Fault?) {
        lock.withLock { persistentFault = fault }
    }

    /// Called at the start of every unsend with the 1-based call number.
    public func onUnsend(_ hook: (@Sendable (Int) async -> Void)?) {
        lock.withLock { onUnsendHook = hook }
    }

    /// Simulates the user unsending a message themselves in the Instagram app.
    public func removeExternally(_ ref: MessageRef) {
        _ = lock.withLock { removed.insert(ref.key) }
    }

    // MARK: Inspection

    public var unsendCalls: Int { lock.withLock { unsendCallCount } }
    public var presenceCalls: Int { lock.withLock { presenceCallCount } }
    public var foreignAttempts: [MessageRef] { lock.withLock { foreignUnsendAttempts } }
    public var maximumPageSizeServed: Int { lock.withLock { largestPage } }
    public var pagesServedCount: Int { lock.withLock { pagesServed } }
    public var removedCount: Int { lock.withLock { removed.count } }
    public func unsendCount(for ref: MessageRef) -> Int { lock.withLock { unsendCounts[ref.key, default: 0] } }
    /// Refs unsent more than once (should always be empty).
    public var repeatedUnsends: [String] { lock.withLock { unsendCounts.filter { $0.value > 1 }.map(\.key) } }

    // MARK: Generation

    private func isOwnerMessage(_ spec: ConversationSpec, index: Int) -> Bool {
        let hasher = SeededRandom(seed: seed &+ UInt64(bitPattern: Int64(spec.id.rawValue.hashValueStable)) &+ UInt64(index) &* 31)
        return hasher.next(below: 100) < spec.ownerShare
    }

    private func message(_ spec: ConversationSpec, index: Int) -> DiscoveredMessage {
        let owned = isOwnerMessage(spec, index: index)
        let kinds: [MessageKind] = [.text, .text, .text, .media, .link, .voice]
        return DiscoveredMessage(
            ref: MessageRef(conversationID: spec.id, messageID: "m\(index)"),
            authorID: owned ? owner.ownerID : other,
            sentAt: baseDate.addingTimeInterval(Double(index) * 90),
            kind: kinds[index % kinds.count]
        )
    }

    private func find(_ ref: MessageRef) -> DiscoveredMessage? {
        guard let spec = specs.first(where: { $0.id == ref.conversationID }),
              ref.messageID.hasPrefix("m"),
              let index = Int(ref.messageID.dropFirst()),
              (0..<spec.messageCount).contains(index) else { return nil }
        return message(spec, index: index)
    }

    // MARK: MessageSource

    public func account() async throws -> AccountIdentity { owner }

    public func conversations() async throws -> [ConversationSummary] {
        specs.map { spec in
            var sent = 0
            var received = 0
            var byKind: [MessageKind: Int] = [:]
            var first: Date?
            var last: Date?
            for index in 0..<spec.messageCount {
                let message = message(spec, index: index)
                if message.authorID == owner.ownerID {
                    guard !lock.withLock({ removed.contains(message.ref.key) }) else { continue }
                    sent += 1
                    byKind[message.kind, default: 0] += 1
                    first = first ?? message.sentAt
                    last = message.sentAt
                } else {
                    received += 1
                }
            }
            return ConversationSummary(
                id: spec.id,
                title: spec.title,
                sentByOwner: sent,
                receivedFromOthers: received,
                firstSentAt: first,
                lastSentAt: last,
                sentByKind: byKind
            )
        }
    }

    public func messagePages(in conversation: ConversationID, pageSize: Int) -> AsyncThrowingStream<[DiscoveredMessage], Error> {
        let spec = specs.first { $0.id == conversation }
        let cursor = PageCursor()
        return AsyncThrowingStream {
            guard let spec, cursor.index < spec.messageCount else { return nil }
            var page: [DiscoveredMessage] = []
            var ownerCount = 0
            while cursor.index < spec.messageCount && page.count < pageSize {
                let message = self.message(spec, index: cursor.index)
                page.append(message)
                if message.authorID == self.owner.ownerID {
                    ownerCount += 1
                    if let every = spec.duplicateEvery, ownerCount % every == 0, page.count < pageSize {
                        page.append(message)
                    }
                }
                cursor.index += 1
            }
            self.lock.withLock {
                self.largestPage = max(self.largestPage, page.count)
                self.pagesServed += 1
            }
            return page
        }
    }

    // MARK: UnsendService

    public func unsend(_ target: CleanupTarget) async throws -> UnsendOutcome {
        let (call, hook) = lock.withLock { () -> (Int, (@Sendable (Int) async -> Void)?) in
            unsendCallCount += 1
            return (unsendCallCount, onUnsendHook)
        }
        await hook?(call)
        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }

        let fault = lock.withLock { scriptedFaults[call] ?? persistentFault }
        guard let message = find(target.ref) else { throw IntegrationError.unexpectedResponse(code: 404) }

        if let fault {
            if fault == .timeoutAfterApplying, message.authorID == owner.ownerID {
                apply(target.ref)
            }
            throw Self.error(for: fault)
        }

        return lock.withLock {
            guard message.authorID == owner.ownerID else {
                foreignUnsendAttempts.append(target.ref)
                return .notOwned
            }
            guard !removed.contains(target.ref.key) else { return .alreadyGone }
            removed.insert(target.ref.key)
            unsendCounts[target.ref.key, default: 0] += 1
            return .unsent
        }
    }

    public func presence(of target: CleanupTarget) async throws -> MessagePresence {
        let call = lock.withLock { () -> Int in
            presenceCallCount += 1
            return presenceCallCount
        }
        if let fault = lock.withLock({ scriptedPresenceFaults[call] }) {
            throw Self.error(for: fault)
        }
        guard let message = find(target.ref) else { return .gone }
        guard message.authorID == owner.ownerID else { return .notOwned }
        return lock.withLock { removed.contains(target.ref.key) } ? .gone : .present
    }

    private func apply(_ ref: MessageRef) {
        lock.withLock {
            if removed.insert(ref.key).inserted {
                unsendCounts[ref.key, default: 0] += 1
            }
        }
    }

    private static func error(for fault: Fault) -> IntegrationError {
        switch fault {
        case let .rateLimited(retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .sessionExpired: return .sessionExpired
        case .verificationRequired: return .verificationRequired
        case .offline: return .offline
        case .timeoutAfterApplying, .timeoutBeforeApplying: return .transportFailure(requestMayHaveBeenApplied: true)
        case .serverError: return .serverUnavailable
        case let .unexpected(code): return .unexpectedResponse(code: code)
        }
    }
}

extension FakeInstagramService {
    /// Sample data for the in-app demo (Debug/Staging only) and UI tests.
    public static func demo(latency: TimeInterval = 0) -> FakeInstagramService {
        FakeInstagramService(
            owner: AccountIdentity(ownerID: ParticipantID("fake:owner"), displayName: "you"),
            conversations: [
                ConversationSpec(id: "demo-bestie", title: "bestie 🫶", messageCount: 240, ownerShare: 52),
                ConversationSpec(id: "demo-group", title: "the group chat", messageCount: 320, ownerShare: 30),
                ConversationSpec(id: "demo-ex", title: "the ex 🚩", messageCount: 120, ownerShare: 60),
                ConversationSpec(id: "demo-roommates", title: "roommates", messageCount: 90, ownerShare: 40),
                ConversationSpec(id: "demo-gym", title: "gym 6am crew", messageCount: 60, ownerShare: 45),
                ConversationSpec(id: "demo-mom", title: "mom", messageCount: 50, ownerShare: 50)
            ],
            seed: 7,
            baseDate: Date(timeIntervalSince1970: 1_560_000_000),
            latency: latency
        )
    }
}

/// Iteration state for a page stream; only touched by that stream's sequential producer.
private final class PageCursor: @unchecked Sendable {
    var index = 0
}

private extension String {
    /// `hashValue` is randomised per process; this one is stable across runs.
    var hashValueStable: Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: hash)
    }
}
