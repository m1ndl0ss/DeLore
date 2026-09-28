import DeLoreCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Route: Equatable {
        case launching
        case welcome
        case connect
        case home
    }

    enum Sheet: Identifiable, Equatable {
        case settings
        case privacy
        case chooseChats
        case included
        case setup(CleanupScope)
        case paywall(AnalyticsEvent.PaywallContext)
        case unavailable

        var id: String {
            switch self {
            case .settings: return "settings"
            case .privacy: return "privacy"
            case .chooseChats: return "chooseChats"
            case .included: return "included"
            case .setup: return "setup"
            case let .paywall(context): return "paywall-\(context.rawValue)"
            case .unavailable: return "unavailable"
            }
        }
    }

    private(set) var route: Route = .launching
    var sheet: Sheet?
    var session: CleanupSessionModel?
    /// The running screen can be tucked away while a job is paused; Home shows a way back.
    var isSessionPresented = false
    var importModel: ImportModel?
    private(set) var overview: LibraryOverview?
    private(set) var isLoadingOverview = false

    let env: AppEnvironment
    var entitlements: EntitlementManager { env.entitlements }

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: Launch

    func bootstrap() async {
        async let minimumSplash: Void = Self.splashDelay()
        await entitlements.refresh()

        if !env.hasCompletedOnboarding {
            _ = await minimumSplash
            withAnimation { route = .welcome }
            return
        }
        if env.hasLibrary {
            await reloadOverview()
            await restoreSession()
            _ = await minimumSplash
            withAnimation { route = .home }
        } else {
            _ = await minimumSplash
            withAnimation { route = .connect }
        }
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
        } catch {
            // Unreadable or half-built job: it was never confirmed or can't be trusted, so drop it.
            env.logger.warning("discarding unreadable job: \(error.safeDescription)")
            try? env.jobStore.discardActiveJob()
        }
    }

    // MARK: Onboarding & import

    func getStarted() {
        env.analytics.track(.onboardingStarted)
        withAnimation { route = .connect }
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

    func useSampleData() async {
        env.enableSampleData()
        env.hasCompletedOnboarding = true
        await reloadOverview()
        withAnimation { route = .home }
    }

    func showConnect() {
        withAnimation { route = .connect }
    }

    func returnHome() {
        guard env.hasLibrary else { return }
        withAnimation { route = .home }
    }

    func reloadOverview() async {
        isLoadingOverview = true
        defer { isLoadingOverview = false }
        overview = try? await env.loadOverview()
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
            sheet = .unavailable
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
    }

    // MARK: Erase

    func eraseEverything() async {
        if let session, !session.isFinished { await session.cancel() }
        isSessionPresented = false
        session = nil
        sheet = nil
        do {
            try env.eraseAllData()
        } catch {
            env.logger.error("erase failed: \(error.safeDescription)")
        }
        overview = nil
        withAnimation { route = .welcome }
    }
}
