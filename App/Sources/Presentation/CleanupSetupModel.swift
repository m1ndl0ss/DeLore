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

    var scopeKind: ScopeKind
    var chosen: Set<ConversationID>
    var useDateFilter = false
    var sentBefore: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var kinds: Set<MessageKind> = Set(CleanupSetupModel.filterableKinds)

    private(set) var isPreparing = false
    private(set) var prepared: PreparedCleanup?
    private(set) var failed = false

    let overview: LibraryOverview
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
        CleanupFilter(
            sentAfter: nil,
            sentBefore: useDateFilter ? sentBefore : nil,
            kinds: kinds.count == Self.filterableKinds.count ? nil : kinds
        )
    }

    var scope: CleanupScope {
        scopeKind == .everything ? .everything : .conversations(chosen)
    }

    var usesAdvancedFilters: Bool { filter.isAdvanced }

    var canContinue: Bool {
        !(scopeKind == .chosen && chosen.isEmpty) && !kinds.isEmpty && estimatedCount > 0
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
        defer { isPreparing = false }
        do {
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
