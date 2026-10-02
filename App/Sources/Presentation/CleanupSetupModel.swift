import DeLoreCore
import Foundation

struct PreparedCleanup: Hashable, Identifiable {
    let job: CleanupJob
    let decision: CleanupAllowanceDecision
    var id: UUID { job.id }
    var count: Int { job.itemCount }
}

/// Holds the user's cleanup choices and turns them into a concrete, counted job that's
/// waiting for explicit confirmation.
@MainActor
@Observable
final class CleanupSetupModel {
    enum ScopeKind: Hashable { case everything, chosen }
    /// Kinds offered as filters. `.other` (reactions, system items) rides along with "all".
    static let filterableKinds: [MessageKind] = [.text, .media, .link, .voice]

    enum DateBound: Hashable {
        case any
        case before
        case after
    }

    var scopeKind: ScopeKind
    var chosen: Set<ConversationID>
    var dateBound: DateBound = .any
    var cutoff: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var kinds: Set<MessageKind> = Set(CleanupSetupModel.filterableKinds)

    private(set) var isPreparing = false
    private(set) var isEvaluating = false
    private(set) var evaluateProgress = InboxReadProgress()
    private(set) var prepared: PreparedCleanup?
    private(set) var failed = false
    private(set) var overview: LibraryOverview

    private let env: AppEnvironment

    init(overview: LibraryOverview, scope: CleanupScope, env: AppEnvironment) {
        self.overview = overview
        self.env = env
        switch scope {
        case .everything:
            scopeKind = .everything
            chosen = []
        case let .conversations(ids):
            scopeKind = .chosen
            chosen = ids
        }
    }

    var filter: CleanupFilter {
        let dayStart = Calendar.current.startOfDay(for: cutoff)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? cutoff
        // Kind filters are intentionally omitted — Instagram's item_type is often wrong
        // (media labeled "text", missing xma_*), so type toggles would silently skip messages.
        switch dateBound {
        case .any:
            return CleanupFilter(sentAfter: nil, sentBefore: nil, kinds: nil)
        case .before:
            return CleanupFilter(sentAfter: nil, sentBefore: nextDay, kinds: nil)
        case .after:
            return CleanupFilter(sentAfter: dayStart, sentBefore: nil, kinds: nil)
        }
    }

    var scope: CleanupScope {
        scopeKind == .everything ? .everything : .conversations(chosen)
    }

    var usesAdvancedFilters: Bool { filter.isAdvanced }

    var canContinue: Bool {
        switch scopeKind {
        case .everything: return !overview.conversations.isEmpty
        case .chosen: return !chosen.isEmpty
        }
    }

    /// Upper bound from summaries; the exact number comes from `prepare()`.
    var estimatedCount: Int {
        QueueBuilder.estimatedCount(for: CleanupRequest(scope: scope, filter: filter), in: overview.conversations)
    }

    var receivedInScope: Int {
        QueueBuilder.targetConversations(for: scope, in: overview.conversations).reduce(0) { $0 + $1.receivedFromOthers }
    }

    func prepare(limit: Int? = nil) async {
        guard !isPreparing else { return }
        isPreparing = true
        failed = false
        defer {
            isEvaluating = false
            isPreparing = false
        }
        do {
            try await refreshChatSizes()

            let request = CleanupRequest(scope: scope, filter: filter, limit: limit)
            let source = env.messageSource
            let store = env.jobStore
            let conversations = overview.conversations
            let now = Date()
            let report = try await Task.detached(priority: .userInitiated) {
                let account = try await source.account()
                return try await QueueBuilder(source: source, store: store)
                    .build(request: request, account: account, conversations: conversations, now: now)
            }.value
            let decision = env.entitlements.allowance(requestedCount: report.job.itemCount, usesAdvancedFilters: usesAdvancedFilters)
            prepared = PreparedCleanup(job: report.job, decision: decision)
        } catch {
            env.logger.error("queue build failed: \(error.safeDescription)")
            failed = true
        }
    }

    /// Loads chats that haven't been sized yet. Results stay on device (`messagesLoaded`) so reopen skips Instagram.
    private func refreshChatSizes() async throws {
        let targets = QueueBuilder.conversationsInScope(for: scope, in: overview.conversations)
        let pending = targets.filter { !$0.messagesLoaded }
        guard !pending.isEmpty else {
            overview = try await env.loadOverview()
            return
        }
        isEvaluating = true
        let titles = pending.map(\.title)
        evaluateProgress = InboxReadProgress(
            chatsFound: pending.count,
            chatsRead: 0,
            chatsTotal: pending.count,
            currentTitle: pending.first?.title,
            foundTitles: titles
        )
        if env.hasLiveSession {
            let ids = pending.map(\.id)
            let titleMap = Dictionary(uniqueKeysWithValues: pending.map { ($0.id.rawValue, $0.title) })
            _ = try await env.loadInbox(ids: ids, titles: titleMap, forceRefresh: false) { progress in
                Task { @MainActor in
                    self.evaluateProgress = progress
                }
            }
        } else {
            for (index, chat) in pending.enumerated() {
                try await Task.sleep(nanoseconds: 90_000_000)
                evaluateProgress = InboxReadProgress(
                    chatsFound: pending.count,
                    chatsRead: index + 1,
                    chatsTotal: pending.count,
                    sendsFound: chat.sentByOwner,
                    currentTitle: chat.title,
                    foundTitles: titles
                )
            }
        }
        isEvaluating = false
        overview = try await env.loadOverview()
    }

    /// Discards a job the user didn't confirm.
    func discardPrepared() {
        guard prepared != nil else { return }
        try? env.jobStore.discardActiveJob()
        prepared = nil
    }

    func clearFailure() {
        failed = false
    }
}
