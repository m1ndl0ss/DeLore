import BackgroundTasks
import DeLoreCore
import Foundation
import UIKit

struct InboxWorkSnapshot: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case list, load }
    var kind: Kind
    var ids: [String]
    var titles: [String: String]
    var retractIds: [String]

    var loadIDs: [ConversationID] { ids.map(ConversationID.init) }
    var retract: Set<ConversationID> { Set(retractIds.map(ConversationID.init)) }

    var job: InboxSyncModel.Job {
        switch kind {
        case .list: return .list
        case .load: return .load(loadIDs)
        }
    }
}

@MainActor
final class BackgroundWorkCenter {
    static let shared = BackgroundWorkCenter()
    static let processingID = "app.delore.ios.processing"
    static let refreshID = "app.delore.ios.refresh"

    private weak var model: AppModel?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static func register() {
        let scheduler = BGTaskScheduler.shared
        scheduler.register(forTaskWithIdentifier: processingID, using: nil) { task in
            Task { @MainActor in
                await shared.handle(task)
            }
        }
        scheduler.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            Task { @MainActor in
                await shared.handle(task)
            }
        }
    }

    func bind(_ model: AppModel) {
        self.model = model
    }

    func didEnterBackground(working: Bool) {
        guard working else { return }
        schedule()
        beginAssertion()
    }

    func didEnterForeground() {
        endAssertion()
    }

    func schedule() {
        let processing = BGProcessingTaskRequest(identifier: Self.processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    private func handle(_ task: BGTask) {
        schedule()
        let once = CompletionOnce()
        task.expirationHandler = {
            once.complete(task, success: false)
            Task { @MainActor in
                self.schedule()
            }
        }
        Task { @MainActor in
            await self.model?.continueBackgroundWork()
            once.complete(task, success: true)
        }
    }

    private func beginAssertion() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "retract-work") { [weak self] in
            MainActor.assumeIsolated {
                self?.endAssertion()
            }
        }
    }

    private func endAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func complete(_ task: BGTask, success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}
