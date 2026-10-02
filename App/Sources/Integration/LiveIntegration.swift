import DeLoreCore
import Foundation

/// Wires the Instagram *website* session into the rest of the app.
///
/// Architecture (same shape UnSendAll describes for iOS):
/// 1. The user signs in through Instagram's own login page (shown in a WKWebView).
/// 2. Session cookies stay on the device, in the Keychain.
/// 3. Discovery and Unsend talk to Instagram's website using that session.
/// 4. Nothing is sent to a Retract server.
///
/// We use Instagram's published website client id (`APP_ID` on instagram.com), not a
/// spoofed iOS/Android app identity. Challenges, CAPTCHAs and checkpoints are shown
/// in Instagram's page or stop the job — they are never solved or bypassed.
enum LiveIntegration {
    static func makeHTTPClient(sessionVault: SessionVault, logger: AppLogger) -> InstagramHTTPClient {
        InstagramHTTPClient(
            transport: URLSessionTransport(),
            sessionProvider: { try sessionVault.loadSession() },
            logger: logger
        )
    }

    /// Prefers the www WKWebView `fetch` path; falls back to URLSession for non-GraphQL.
    static func makeAPIClient(
        sessionVault: SessionVault,
        logger: AppLogger,
        webGateway: InstagramWebViewGateway? = nil
    ) -> InstagramAPIClient {
        if let webGateway {
            return InstagramWebViewAPIClient(gateway: webGateway, sessionVault: sessionVault)
        }
        return makeHTTPClient(sessionVault: sessionVault, logger: logger)
    }

    static func makeUnsendService(
        sessionVault: SessionVault,
        logger: AppLogger,
        webGateway: InstagramWebViewGateway? = nil
    ) -> InstagramWebUnsendService {
        let client = makeAPIClient(sessionVault: sessionVault, logger: logger, webGateway: webGateway)
        return InstagramWebUnsendService(
            client: client,
            ownerID: { try sessionVault.loadSession()?.userID }
        )
    }

    static func makeInboxSync(
        sessionVault: SessionVault,
        library: LocalLibraryStore,
        logger: AppLogger,
        webGateway: InstagramWebViewGateway? = nil
    ) -> InstagramInboxSync {
        InstagramInboxSync(
            client: makeAPIClient(sessionVault: sessionVault, logger: logger, webGateway: webGateway),
            library: library
        )
    }
}
