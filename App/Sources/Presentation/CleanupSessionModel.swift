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
    /// Only touched on the main actor, plus `deinit` once no other reference exists.
    @ObservationIgnored private nonisolated(unsafe) var observation: Task<Void, Never>?
    var onActivityChanged: (() -> Void)?
    var onCleaned: ((Set<String>) -> Void)?
    private var lastCompleted = -1
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
        let cleaned = await engine.cancel()
        await refresh()
        onActivityChanged?()
        onCleaned?(cleaned)
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) async {
        switch phase {
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
        let changed = update.completed != lastCompleted || update.status != progress.status
        progress = update
        UIApplication.shared.isIdleTimerDisabled = update.status == .running
        if changed {
            lastCompleted = update.completed
            onActivityChanged?()
        }
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
        onCleaned?(engine.completedKeys())
        onActivityChanged?()
    }
}
