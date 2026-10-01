import DeLoreCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Route: Equatable {
        case launching
        case home
    }

    enum Tab: String, CaseIterable, Identifiable {
        case unsending
        case activity
        case settings
        var id: String { rawValue }
    }

    enum LoginPurpose: String, Identifiable, Equatable {
        case connect
        case reconnect
        case refresh

        var id: String { rawValue }
    }

    enum TermsPrompt: String, Identifiable, Equatable {
        case signup
        case reminder

        var id: String { rawValue }
    }

    enum Sheet: Identifiable, Equatable {
        case settings
        case privacy
        case support
        case terms
        case chooseChats
        case included
        case setup(CleanupScope)
        case paywall(AnalyticsEvent.PaywallContext)
        case unavailable

        var id: String {
            switch self {
            case .settings: return "settings"
            case .privacy: return "privacy"
            case .support: return "support"
            case .terms: return "terms"
            case .chooseChats: return "chooseChats"
            case .included: return "included"
            case .setup: return "setup"
            case let .paywall(context): return "paywall-\(context.rawValue)"
            case .unavailable: return "unavailable"
            }
        }
    }

    private(set) var route: Route = .launching
    var tab: Tab = .unsending
    private var didPromptDeletionLogin = false
    var sheet: Sheet?
    var session: CleanupSessionModel?
    /// The running screen can be tucked away while a job is paused; Home shows a way back.
    var isSessionPresented = false
    var importModel: ImportModel?
    var inboxSyncModel: InboxSyncModel?
    var loginPurpose: LoginPurpose?
    var termsPrompt: TermsPrompt?
    private var termsNoticeDismissedThisLaunch = false
    private var pendingRetractIDs: Set<ConversationID> = []
    private var lastInboxJob: InboxSyncModel.Job = .list
    private(set) var overview: LibraryOverview?
    private(set) var isLoadingOverview = false
    private(set) var history: [CleanupHistoryEntry] = []

    let env: AppEnvironment
    var entitlements: EntitlementManager { env.entitlements }

    init(env: AppEnvironment) {
        self.env = env
        BackgroundWorkCenter.shared.bind(self)
    }

    // MARK: Launch

    func bootstrap() async {
        async let minimumSplash: Void = Self.splashDelay()
        await entitlements.refresh()
        env.dropStaleFullInbox()

        if env.hasLibrary {
            await reloadOverview()
        }
        await restoreSession()
        resumePersistedInbox()
        _ = await minimumSplash
        env.inboxHoldOffUntil = nil
        withAnimation { route = .home }
        maybeShowTermsNotice()
    }

    private nonisolated static func splashDelay() async {
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    private func restoreSession() async {
        do {
            guard let engine = try CleanupEngine.loadActive(dependencies: env.engineDependencies()) else { return }
            let progress = await engine.progress()
            let job = await engine.currentJob
            if progress.status.isFinished || job.authorizedAt == nil {
                try? env.jobStore.discardActiveJob()
                return
            }
            session = CleanupSessionModel(engine: engine, initial: progress, entitlements: entitlements)
            isSessionPresented = true
            switch job.status {
            case .ready, .paused(.interrupted), .paused(.appInBackground):
                await session?.resume()
            default:
                break
            }
        } catch {
            // Unreadable or half-built job: it was never confirmed or can't be trusted, so drop it.
            env.logger.warning("discarding unreadable job: \(error.safeDescription)")
            try? env.jobStore.discardActiveJob()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            BackgroundWorkCenter.shared.didEnterBackground(working: hasBackgroundWork)
        case .active:
            BackgroundWorkCenter.shared.didEnterForeground()
            await session?.scenePhaseChanged(.active)
        default:
            break
        }
    }

    func continueBackgroundWork() async {
        if session == nil {
            await restoreSession()
        } else {
            await session?.scenePhaseChanged(.active)
        }
        if inboxSyncModel == nil {
            resumePersistedInbox()
        }
        while hasBackgroundWork {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var hasBackgroundWork: Bool {
        if session?.isRunning == true { return true }
        if case .running = inboxSyncModel?.phase { return true }
        return false
    }

    private func resumePersistedInbox() {
        guard inboxSyncModel == nil, env.hasLiveSession, !env.isInboxOnHold else { return }
        if let snapshot = env.loadInboxWork() {
            pendingRetractIDs.formUnion(snapshot.retract)
            beginInboxSync(force: true, job: snapshot.job)
            return
        }
        let queued = env.loadRetractQueue()
        guard !queued.isEmpty else { return }
        pendingRetractIDs.formUnion(queued)
        Task { await finishInboxSync() }
    }

    // MARK: Onboarding & import

    func beginLogin(_ purpose: LoginPurpose = .connect) {
        if purpose == .connect, !env.hasAcceptedTerms {
            termsPrompt = .signup
            loginPurpose = nil
            return
        }
        termsPrompt = nil
        loginPurpose = purpose
    }

    func cancelTermsPrompt() {
        if termsPrompt == .reminder { termsNoticeDismissedThisLaunch = true }
        termsPrompt = nil
    }

    func acceptTermsPrompt(dontShowAgain: Bool = true) {
        let prompt = termsPrompt
        termsPrompt = nil
        if prompt == .signup || dontShowAgain {
            env.acceptedTermsVersion = LegalCopy.termsVersion
        } else {
            termsNoticeDismissedThisLaunch = true
        }
        guard prompt == .signup else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard env.hasAcceptedTerms else { return }
            loginPurpose = .connect
        }
    }

    func maybeShowTermsNotice() {
        guard !env.hasAcceptedTerms, env.hasLiveSession, !termsNoticeDismissedThisLaunch else { return }
        if isSessionPresented, let session, !session.isFinished { return }
        guard termsPrompt == nil, loginPurpose == nil else { return }
        termsPrompt = .reminder
    }

    func cancelLogin() {
        loginPurpose = nil
    }

    func handleLogin(_ session: InstagramWebSession, purpose: LoginPurpose) {
        do {
            try env.saveInstagramSession(session)
        } catch {
            env.logger.error("could not keep Instagram session: \(error.safeDescription)")
            loginPurpose = nil
            return
        }
        loginPurpose = nil
        let shouldSync: Bool
        switch purpose {
        case .connect, .refresh:
            shouldSync = true
        case .reconnect:
            shouldSync = !env.hasLibrary
        }
        if shouldSync {
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                beginInboxSync(force: true)
            }
        } else {
            maybeShowTermsNotice()
        }
    }

    func beginInboxSync(force: Bool = false, job: InboxSyncModel.Job = .list) {
        if !force, env.isInboxOnHold { return }
        env.inboxHoldOffUntil = nil
        lastInboxJob = job
        sheet = nil
        env.saveRetractQueue(pendingRetractIDs)
        let previous = inboxSyncModel?.latest.foundTitles ?? []
        inboxSyncModel?.cancel()
        let fromOverview = overview?.conversations.map(\.title) ?? []
        let seed: [String]
        var titlesByID: [String: String] = [:]
        switch job {
        case .list:
            seed = fromOverview.isEmpty ? previous : fromOverview
        case let .load(ids):
            let people = overview?.conversations ?? []
            titlesByID = Dictionary(
                ids.map { id in
                    (id.rawValue, people.first { $0.id.rawValue == id.rawValue }?.title ?? "Chat")
                },
                uniquingKeysWith: { first, _ in first }
            )
            seed = ids.map { titlesByID[$0.rawValue] ?? "Chat" }
        }
        let model = InboxSyncModel(env: env, job: job, seedTitles: seed, titlesByID: titlesByID)
        model.onFinished = { [weak self] _ in
            Task { await self?.finishInboxSync() }
        }
        model.onFailed = { [weak self] in
            Task { await self?.reloadOverview() }
        }
        inboxSyncModel = model
        model.start()
    }

    func retractWith(_ ids: Set<ConversationID>) {
        guard !ids.isEmpty else { return }
        pendingRetractIDs = ids
        env.saveRetractQueue(ids)
        let wanted = Set(ids.map(\.rawValue))
        let unread = (overview?.conversations ?? []).filter { wanted.contains($0.id.rawValue) && !$0.messagesLoaded }
        if unread.isEmpty {
            pendingRetractIDs = []
            env.saveRetractQueue([])
            openSetup(.conversations(ids))
            return
        }
        beginInboxSync(force: true, job: .load(unread.map(\.id)))
    }

    func dismissSync() {
        pendingRetractIDs = []
        env.saveRetractQueue([])
        env.saveInboxWork(nil)
        inboxSyncModel?.cancel()
        inboxSyncModel = nil
        Task { await reloadOverview() }
        maybeShowTermsNotice()
    }

    func acceptInboxHoldOff(later: Bool) {
        let suggested = inboxSyncModel?.retryAfter ?? 0
        let base = later ? InboxSyncModel.laterSeconds : InboxSyncModel.waitSeconds
        env.inboxHoldOffUntil = Date().addingTimeInterval(max(base, suggested))
        dismissSync()
    }

    func retryInboxNow() {
        env.inboxHoldOffUntil = nil
        if env.hasLiveSession {
            beginInboxSync(force: true, job: lastInboxJob)
        } else {
            beginLogin(.refresh)
        }
    }

    func retryInboxWhenAllowed() {
        retryInboxNow()
    }

    func signInAgainFromSync() {
        dismissSync()
        beginLogin(.refresh)
    }

    func refreshChats() {
        if env.hasLiveSession {
            lastInboxJob = .list
            pendingRetractIDs = []
            env.saveRetractQueue([])
            env.inboxListCursor = nil
            beginInboxSync(force: true, job: .list)
        } else {
            beginLogin(.refresh)
        }
    }

    func beginImport(from url: URL) {
        let model = ImportModel(url: url, library: env.library, analytics: env.analytics)
        model.onFinished = { [weak self] _ in
            Task { await self?.finishImport() }
        }
        importModel = model
        model.start()
    }

    func dismissImport() {
        importModel?.cancel()
        importModel = nil
    }

    private func finishImport() async {
        if !env.hasCompletedOnboarding {
            env.hasCompletedOnboarding = true
            env.analytics.track(.onboardingCompleted)
        }
        await reloadOverview()
        importModel = nil
        withAnimation { route = .home }
    }

    private func finishInboxSync() async {
        if !env.hasCompletedOnboarding {
            env.hasCompletedOnboarding = true
            env.analytics.track(.onboardingCompleted)
        }
        await reloadOverview()
        inboxSyncModel = nil
        env.saveInboxWork(nil)
        withAnimation { route = .home }
        let ids = pendingRetractIDs.union(env.loadRetractQueue())
        pendingRetractIDs = []
        env.saveRetractQueue([])
        if !ids.isEmpty {
            let wanted = Set(ids.map(\.rawValue))
            let cleanable = Set(
                (overview?.cleanableConversations ?? [])
                    .filter { wanted.contains($0.id.rawValue) }
                    .map(\.id)
            )
            if !cleanable.isEmpty { openSetup(.conversations(cleanable)) }
        }
        maybeShowTermsNotice()
    }

    func showConnect() {
        tab = .unsending
        if env.hasLiveSession {
            lastInboxJob = .list
            pendingRetractIDs = []
            env.saveRetractQueue([])
            beginInboxSync(force: true, job: .list)
        } else {
            beginLogin(.connect)
        }
    }

    func returnHome() {
        withAnimation { route = .home }
    }

    func deletionAppeared() {
        if env.hasLiveSession {
            if !env.hasLibrary { beginInboxSync() }
            return
        }
        guard !didPromptDeletionLogin else { return }
        didPromptDeletionLogin = true
        beginLogin(.connect)
    }

    func reloadOverview() async {
        isLoadingOverview = true
        defer { isLoadingOverview = false }
        overview = try? await env.loadOverview()
        history = (try? env.history.load())?.reversed() ?? []
    }

    // MARK: Cleanup

    var hasUnfinishedSession: Bool { session.map { !$0.isFinished } ?? false }

    /// Entry point for "Clean up" / "Choose chats" once scope is known. Only one job exists
    /// at a time, so an unfinished one is reopened instead of being replaced.
    func openSetup(_ scope: CleanupScope) {
        if hasUnfinishedSession {
            sheet = nil
            isSessionPresented = true
            return
        }
        guard env.isCleanupAvailable else {
            beginLogin(.reconnect)
            return
        }
        sheet = .setup(scope)
    }

    /// Starts a confirmed job, charging the right entitlement.
    func startCleanup(_ prepared: PreparedCleanup) async {
        guard case let .allowed(_, consumesPass, usesFreeAllowance) = prepared.decision else { return }
        let billing: CleanupBilling
        if consumesPass {
            guard entitlements.consumePass() else { return }
            billing = .pass
        } else if usesFreeAllowance {
            billing = .free
        } else {
            billing = .pro
        }
        CleanupBilling.record(billing, for: prepared.job.id)

        do {
            guard let engine = try CleanupEngine.loadActive(dependencies: env.engineDependencies()) else { return }
            let model = CleanupSessionModel(engine: engine, initial: await engine.progress(), entitlements: entitlements)
            sheet = nil
            session = model
            isSessionPresented = true
            await model.authorizeAndStart()
        } catch {
            env.logger.error("could not start job: \(error.safeDescription)")
        }
    }

    func closeSession(thenChooseChats: Bool = false) async {
        guard let session, session.isFinished else { return }
        isSessionPresented = false
        self.session = nil
        try? env.jobStore.discardActiveJob()
        await reloadOverview()
        if thenChooseChats { sheet = .chooseChats }
        maybeShowTermsNotice()
    }

    // MARK: Erase

    func eraseEverything() async {
        if let session, !session.isFinished { await session.cancel() }
        isSessionPresented = false
        session = nil
        sheet = nil
        loginPurpose = nil
        termsPrompt = nil
        inboxSyncModel?.cancel()
        inboxSyncModel = nil
        do {
            try env.eraseAllData()
        } catch {
            env.logger.error("erase failed: \(error.safeDescription)")
        }
        overview = nil
        history = []
        didPromptDeletionLogin = false
        tab = .settings
        withAnimation { route = .home }
    }
}
