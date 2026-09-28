import DeLoreCore
import Foundation

@MainActor
@Observable
final class InboxSyncModel: Identifiable {
    enum Phase: Equatable {
        case running(Double)
        case failed(title: String, message: String)
        case finished
    }

    let id = UUID()
    private(set) var phase: Phase = .running(0)
    private let env: AppEnvironment
    var onFinished: ((LibraryOverview) -> Void)?
    private var work: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        env.analytics.track(.importStarted)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let overview = try await self.env.syncInbox { [weak self] progress in
                    Task { @MainActor in self?.update(progress) }
                }
                self.env.analytics.track(.importCompleted(size: .init(count: overview.sentByOwner)))
                self.phase = .finished
                self.onFinished?(overview)
            } catch is CancellationError {
                self.env.analytics.track(.importFailed(reason: .cancelled))
            } catch {
                self.env.analytics.track(.importFailed(reason: .unreadable))
                self.phase = .failed(title: Self.title(for: error), message: Self.message(for: error))
            }
        }
    }

    func cancel() {
        work?.cancel()
    }

    private func update(_ value: Double) {
        if case .running = phase { phase = .running(value) }
    }

    static func title(for error: Error) -> String {
        switch error as? IntegrationError {
        case .sessionExpired: return String(localized: "Instagram signed you out")
        case .verificationRequired: return String(localized: "Instagram is asking you to verify your account.")
        case .rateLimited: return String(localized: "We've paused to keep your account safe.")
        case .offline: return String(localized: "You're offline")
        default: return String(localized: "We couldn't read your DMs")
        }
    }

    static func message(for error: Error) -> String {
        switch error as? IntegrationError {
        case .sessionExpired: return String(localized: "Sign in again, then we'll pick up where we left off.")
        case .verificationRequired: return String(localized: "Open Instagram, follow its steps, then come back. We won't skip that check.")
        case .rateLimited: return String(localized: "Instagram asked us to slow down. Try again later.")
        case .offline: return String(localized: "Connect to the internet and try again.")
        default: return String(localized: "Try connecting again in a bit.")
        }
    }
}
