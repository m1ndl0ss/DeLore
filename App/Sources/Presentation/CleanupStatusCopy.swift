import DeLoreCore
import Foundation

/// Human-readable copy for every engine state. No technical terms, no blame, and never a
/// suggestion to get around a platform safety check.
struct CleanupStatusCopy: Equatable {
    enum Tone: Equatable { case normal, caution }
    enum Action: Equatable { case pause, resume, tryAgain, resumeAfterVerifying, none }

    let headline: String
    let message: String?
    let tone: Tone
    let action: Action

    static func make(for status: JobStatus, coolingDownUntil: Date?, now: Date = Date()) -> CleanupStatusCopy {
        switch status {
        case .ready, .running:
            if let until = coolingDownUntil, until > now {
                return CleanupStatusCopy(
                    headline: String(localized: "Taking a breather…"),
                    message: String(localized: "Instagram asked us to slow down, so we're pausing to keep your account safe. Back at it around \(until.formatted(date: .omitted, time: .shortened))."),
                    tone: .caution,
                    action: .pause
                )
            }
            return CleanupStatusCopy(headline: String(localized: "Cleaning your digital past…"), message: nil, tone: .normal, action: .pause)
        case .completed:
            return CleanupStatusCopy(headline: String(localized: "Fresh start ✨"), message: nil, tone: .normal, action: .none)
        case .cancelled:
            return CleanupStatusCopy(headline: String(localized: "Cleanup stopped"), message: String(localized: "Anything already unsent stays unsent."), tone: .normal, action: .none)
        case let .paused(reason):
            return copy(for: reason)
        }
    }

    static func copy(for reason: PauseReason) -> CleanupStatusCopy {
        switch reason {
        case .user:
            return CleanupStatusCopy(headline: String(localized: "Paused"), message: String(localized: "Pick up whenever you're ready."), tone: .normal, action: .resume)
        case .appInBackground:
            return CleanupStatusCopy(headline: String(localized: "Paused while you were away"), message: String(localized: "Cleaning only runs while the app is open. We'll keep going now that you're back."), tone: .normal, action: .resume)
        case .interrupted:
            return CleanupStatusCopy(headline: String(localized: "Welcome back"), message: String(localized: "The app closed mid-clean. Your progress is saved, so you can pick up where you left off."), tone: .normal, action: .resume)
        case .rateLimited:
            return CleanupStatusCopy(headline: String(localized: "We've paused the cleanup to keep your account safe."), message: String(localized: "Instagram asked us to slow down a few times in a row. Try again later."), tone: .caution, action: .tryAgain)
        case .sessionExpired:
            return CleanupStatusCopy(headline: String(localized: "Instagram signed you out"), message: String(localized: "Reconnect your account, then come back to continue. Nothing else was touched."), tone: .caution, action: .resumeAfterVerifying)
        case .verificationRequired:
            return CleanupStatusCopy(headline: String(localized: "Instagram is asking you to verify your account."), message: String(localized: "We've paused the cleanup to keep your account safe. Open Instagram and follow its steps, then come back here."), tone: .caution, action: .resumeAfterVerifying)
        case .repeatedFailures:
            return CleanupStatusCopy(headline: String(localized: "We've paused the cleanup to keep your account safe."), message: String(localized: "Instagram isn't responding the way it should right now. Try again later."), tone: .caution, action: .tryAgain)
        case .offline:
            return CleanupStatusCopy(headline: String(localized: "You're offline"), message: String(localized: "We'll carry on as soon as you're back online."), tone: .caution, action: .tryAgain)
        case .unexpectedResponse:
            return CleanupStatusCopy(headline: String(localized: "We stopped to be safe"), message: String(localized: "Instagram replied in a way we didn't expect. Try again later; we'll double-check before touching anything."), tone: .caution, action: .tryAgain)
        case .integrationUnavailable:
            return CleanupStatusCopy(headline: String(localized: "Unsending isn't available yet"), message: String(localized: "Instagram doesn't currently let apps unsend messages for you. Nothing was changed."), tone: .caution, action: .none)
        case .storageFailure:
            return CleanupStatusCopy(headline: String(localized: "We couldn't save your progress"), message: String(localized: "Free up some space on your phone, then try again. Nothing was sent that we couldn't track."), tone: .caution, action: .tryAgain)
        }
    }
}

enum TimeRemainingCopy {
    static func text(for seconds: TimeInterval?) -> String {
        guard let seconds else { return String(localized: "Working out how long this takes…") }
        if seconds < 60 { return String(localized: "Less than a minute left") }
        let duration = Duration.seconds(Int(seconds.rounded()))
        let formatted = duration.formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: seconds >= 3_600 ? 1 : 2))
        return String(localized: "About \(formatted) remaining")
    }
}
