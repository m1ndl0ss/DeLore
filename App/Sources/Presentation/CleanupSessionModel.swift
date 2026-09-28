import DeLoreCore
import SwiftUI
import UIKit

/// Drives the running screen: mirrors engine progress, handles app lifecycle, and keeps
/// the screen awake only while actually cleaning.
@MainActor
@Observable
final class CleanupSessionModel: Identifiable {
    let id: UUID
    private(set) var progress: CleanupProgress
    private(set) var isBusy = false
    /// Set when the user tries to resume before a cool-down has passed.
    private(set) var tryAgainAt: Date?

    private let engine: CleanupEngine
    private let entitlements: EntitlementManager
    private var observation: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var finishHandled = false

    init(engine: CleanupEngine, initial: CleanupProgress, entitlements: EntitlementManager) {
        self.engine = engine
        self.entitlements = entitlements
        id = initial.jobID
        progress = initial
        observe()
    }

    deinit {
        observation?.cancel()
    }

    var copy: CleanupStatusCopy {
        CleanupStatusCopy.make(for: progress.status, coolingDownUntil: progress.resumeNotBefore)
    }

    var isFinished: Bool { progress.status.isFinished }
    var isRunning: Bool { progress.status == .running }

    // MARK: Actions

    /// Records the user's confirmation and starts. Called once, from the confirmation screen.
    func authorizeAndStart() async {
        do {
            try await engine.authorize()
            try await engine.start()
        } catch {
            await refresh()
        }
    }

    func pause() async {
        await engine.pause()
        await refresh()
    }

    func resume(userResolvedIssue: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await engine.start(userResolvedIssue: userResolvedIssue)
            tryAgainAt = nil
        } catch let CleanupEngineError.coolingDown(until) {
            tryAgainAt = until
        } catch {
            // Already running or finished: the refreshed state says what to show.
        }
        await refresh()
    }

    func cancel() async {
        await engine.cancel()
        await refresh()
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            guard progress.status == .running else { return }
            // Ask iOS for a moment so an in-flight request finishes and is recorded.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "finish-current-message") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
            await engine.suspendForBackground()
            await engine.waitUntilStopped()
            await refresh()
            endBackgroundTask()
        case .active:
            try? await engine.resumeAfterBackground()
            await refresh()
        default:
            break
        }
    }

    func connectivityChanged(isOnline: Bool) async {
        guard isOnline, progress.status == .paused(.offline) else { return }
        await resume()
    }

    // MARK: Internals

    private func observe() {
        observation?.cancel()
        observation = Task { [weak self, engine] in
            let updates = await engine.updates()
            for await update in updates {
                self?.apply(update)
            }
        }
    }

    private func refresh() async {
        apply(await engine.progress())
    }

    private func apply(_ update: CleanupProgress) {
        progress = update
        UIApplication.shared.isIdleTimerDisabled = update.status == .running
        if update.status.isFinished { handleFinish() }
    }

    private func handleFinish() {
        guard !finishHandled else { return }
        finishHandled = true
        if CleanupBilling.billing(for: id) == .free {
            entitlements.recordFreeUsage(progress.completed)
        }
        CleanupBilling.clear(for: id)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
