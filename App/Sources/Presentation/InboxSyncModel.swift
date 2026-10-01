import DeLoreCore
import Foundation

@MainActor
@Observable
final class InboxSyncModel: Identifiable {
    enum Kind: Equatable {
        case holdOff
        case reconnect
        case verify
        case offline
    }

    enum Phase: Equatable {
        case running(InboxReadProgress)
        case failed(title: String, message: String, kind: Kind)
        case finished
    }

    enum Job: Equatable {
        case list
        case load([ConversationID])
    }

    let id = UUID()
    private(set) var phase: Phase = .running(InboxReadProgress())
    private(set) var latest = InboxReadProgress()
    private(set) var retryAfter: TimeInterval?
    private let env: AppEnvironment
    private let job: Job
    private let titlesByID: [String: String]
    var onFinished: ((LibraryOverview) -> Void)?
    var onFailed: (() -> Void)?
    private var work: Task<Void, Never>?

    init(env: AppEnvironment, job: Job = .list, seedTitles: [String] = [], titlesByID: [String: String] = [:]) {
        self.env = env
        self.job = job
        self.titlesByID = titlesByID
        switch job {
        case .list:
            latest = InboxReadProgress(chatsFound: seedTitles.count, foundTitles: seedTitles)
        case let .load(ids):
            latest = InboxReadProgress(
                chatsFound: seedTitles.count,
                chatsRead: 0,
                chatsTotal: ids.count,
                currentTitle: seedTitles.first,
                foundTitles: seedTitles
            )
        }
        phase = .running(latest)
    }

    func start() {
        env.analytics.track(.importStarted)
        persistWork()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let overview: LibraryOverview
                switch self.job {
                case .list:
                    overview = try await self.env.listInbox { [weak self] progress in
                        Task { @MainActor in self?.update(progress) }
                    }
                case let .load(ids):
                    overview = try await self.env.loadInbox(ids: ids, titles: self.titlesByID) { [weak self] progress in
                        Task { @MainActor in self?.update(progress) }
                    }
                }
                self.env.analytics.track(.importCompleted(size: .init(count: overview.sentByOwner)))
                self.env.saveInboxWork(nil)
                self.phase = .finished
                self.onFinished?(overview)
            } catch is CancellationError {
                self.env.analytics.track(.importFailed(reason: .cancelled))
            } catch {
                self.env.analytics.track(.importFailed(reason: .unreadable))
                let pause = Self.pause(for: error)
                self.retryAfter = pause.retryAfter
                if pause.kind == .holdOff {
                    self.env.inboxHoldOffUntil = Date().addingTimeInterval(pause.retryAfter ?? Self.waitSeconds)
                }
                self.phase = .failed(title: pause.title, message: pause.message, kind: pause.kind)
                self.onFailed?()
            }
        }
    }

    func cancel() {
        work?.cancel()
    }

    private func update(_ value: InboxReadProgress) {
        latest = value
        if case .running = phase { phase = .running(value) }
        persistWork()
    }

    private func persistWork() {
        let retract = env.loadRetractQueue().map(\.rawValue)
        switch job {
        case .list:
            env.saveInboxWork(InboxWorkSnapshot(kind: .list, ids: [], titles: titlesByID, retractIds: retract))
        case let .load(ids):
            let remaining = Array(ids.dropFirst(max(0, latest.chatsRead)))
            env.saveInboxWork(
                InboxWorkSnapshot(
                    kind: .load,
                    ids: remaining.map(\.rawValue),
                    titles: titlesByID,
                    retractIds: retract
                )
            )
        }
    }

    private struct Pause {
        var title: String
        var message: String
        var kind: Kind
        var retryAfter: TimeInterval?
    }

    static let waitSeconds: TimeInterval = 10 * 60
    static let laterSeconds: TimeInterval = 60 * 60

    private static func pause(for error: Error) -> Pause {
        switch error as? IntegrationError {
        case .sessionExpired:
            return Pause(
                title: String(localized: "Instagram signed you out"),
                message: String(localized: "Sign in again when you're ready. Nothing left this phone."),
                kind: .reconnect,
                retryAfter: nil
            )
        case .verificationRequired:
            return Pause(
                title: String(localized: "Instagram is asking you to verify."),
                message: String(localized: "Do that in Instagram, then come back. We won't skip that check, and we won't keep reading while it's pending."),
                kind: .verify,
                retryAfter: nil
            )
        case let .rateLimited(retryAfter):
            return Pause(
                title: String(localized: "We'll hold off for a bit."),
                message: String(localized: "Instagram asked us to slow down. That's a cue to stop reading, not a prompt to retry. Your login stays on this phone."),
                kind: .holdOff,
                retryAfter: retryAfter
            )
        case .offline:
            return Pause(
                title: String(localized: "You're offline"),
                message: String(localized: "Reconnect to the internet, then we can keep reading from this phone."),
                kind: .offline,
                retryAfter: nil
            )
        case .unexpectedResponse:
            return Pause(
                title: String(localized: "We'll hold off for a bit."),
                message: String(localized: "Instagram didn't hand over your inbox cleanly. Waiting is safer than poking it again. Your login stays on this phone."),
                kind: .holdOff,
                retryAfter: nil
            )
        case .transportFailure, .serverUnavailable:
            return Pause(
                title: String(localized: "We'll hold off for a bit."),
                message: String(localized: "Instagram went quiet, so we stopped instead of keeping at it. Give it a breather — your login stays on this phone."),
                kind: .holdOff,
                retryAfter: nil
            )
        default:
            return Pause(
                title: String(localized: "We'll hold off for a bit."),
                message: String(localized: "We couldn't finish reading without making noise. Sitting this out is the move. Your login stays on this phone."),
                kind: .holdOff,
                retryAfter: nil
            )
        }
    }
}
