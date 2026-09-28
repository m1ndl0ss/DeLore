import DeLoreCore
import Foundation

/// The single place where a live Instagram unsend integration plugs in.
///
/// Instagram does not offer an official API that lets a third-party app unsend messages from
/// a personal account. Every unofficial route we evaluated depends on impersonating
/// Instagram's own apps (private endpoints, client identifiers, device signatures) and
/// operating outside Meta's terms, which is exactly the kind of platform-evasion this product
/// refuses to ship. So Release builds use `UnavailableUnsendService`: discovery, planning and
/// the whole cleanup engine work, and the app tells people plainly that unsending isn't
/// available yet instead of pretending.
///
/// To add an officially supported integration:
/// 1. Implement `UnsendService` (and `MessageSource` if it also provides discovery) using
///    `HTTPClient` + `URLSessionTransport`. Map responses with
///    `NetworkError.integrationError(destructive:)` and add platform-specific signals
///    (e.g. checkpoint bodies → `.verificationRequired`).
/// 2. Keep any credential it needs in `SessionVault` (Keychain), never in UserDefaults.
/// 3. Never retry inside `unsend`; the engine owns retries and reconciliation.
/// 4. Return it from `makeUnsendService`.
enum LiveIntegration {
    static func makeUnsendService(sessionVault: SessionVault, logger: AppLogger) -> UnsendService {
        UnavailableUnsendService()
    }
}
