import DeLoreCore
import Foundation

/// Human-readable copy for every engine state. No technical terms, no blame, and never a
/// suggestion to get around a platform safety check.
struct CleanupStatusCopy: Equatable {
    enum Tone: Equatable { case normal, caution }
    enum Action: Equatable { case pause, resume, tryAgain, resumeAfterVerifying, reconnect, none }

    let headline: String
    let message: String?
    let tone: Tone
    let action: Action

    static func make(for status: JobStatus, coolingDownUntil: Date?, now: Date = Date(), processed: Int = -1) -> CleanupStatusCopy {
        switch status {
        case .ready, .running:
            if let until = coolingDownUntil, until > now {
                return CleanupStatusCopy(
                    headline: String(localized: "Instagram asked us to wait"),
                    message: String(localized: "We're slowing down because Instagram asked us to wait. Back at it around \(until.formatted(date: .omitted, time: .shortened))."),
                    tone: .caution,
                    action: .pause
                )
            }
            let hint: String? = processed == 0
                ? String(localized: "The first unsend can take a minute — we're lining your messages up with Instagram's chat history. After that, it usually picks up.")
                : nil
            return CleanupStatusCopy(headline: String(localized: "Cleaning your digital past…"), message: hint, tone: .normal, action: .pause)
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
            return CleanupStatusCopy(headline: String(localized: "Paused"), message: String(localized: "Tap Resume. We won't unsend the same message twice."), tone: .normal, action: .resume)
        case .appInBackground:
            return CleanupStatusCopy(headline: String(localized: "Paused while you were away"), message: String(localized: "We'll keep going in the background. Tap Resume if we're waiting — we won't unsend twice."), tone: .normal, action: .resume)
        case .interrupted:
            return CleanupStatusCopy(headline: String(localized: "Pick up where you left off"), message: String(localized: "We'll continue automatically. Tap Resume if we're waiting — we won't unsend the same message twice."), tone: .normal, action: .resume)
        case .rateLimited:
            return CleanupStatusCopy(headline: String(localized: "Instagram asked us to wait"), message: String(localized: "We've paused because Instagram asked us to wait. We'll try again automatically."), tone: .caution, action: .tryAgain)
        case .sessionExpired:
            return CleanupStatusCopy(headline: String(localized: "Instagram signed you out"), message: String(localized: "Reconnect your account, then come back to continue. Nothing else was touched."), tone: .caution, action: .reconnect)
        case .verificationRequired:
            return CleanupStatusCopy(headline: String(localized: "Instagram is asking you to verify your account."), message: String(localized: "Open Instagram and follow its steps, then come back here. Retract isn't responsible for what Instagram does."), tone: .caution, action: .resumeAfterVerifying)
        case .repeatedFailures:
            return CleanupStatusCopy(headline: String(localized: "Instagram isn't cooperating"), message: String(localized: "Instagram stopped responding. We'll try again in about 3 minutes — you can leave Retract open in the background."), tone: .caution, action: .tryAgain)
        case .offline:
            return CleanupStatusCopy(headline: String(localized: "You're offline"), message: String(localized: "We'll carry on as soon as you're back online."), tone: .caution, action: .tryAgain)
        case .unexpectedResponse:
            return CleanupStatusCopy(headline: String(localized: "We stopped"), message: String(localized: "Instagram replied in a way we didn't expect. Try again later; we'll double-check before touching anything."), tone: .caution, action: .tryAgain)
        case .integrationUnavailable:
            return CleanupStatusCopy(headline: String(localized: "We couldn't unsend just now"), message: String(localized: "Instagram didn't let this cleanup continue. Nothing else was changed."), tone: .caution, action: .none)
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
