import Foundation

public struct InstagramAPIRequest: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String]
    public var body: Sensitive<Data>?
    public var isIdempotent: Bool
    public var destructive: Bool

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String] = [:],
        body: Sensitive<Data>? = nil,
        isIdempotent: Bool? = nil,
        destructive: Bool = false
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.isIdempotent = isIdempotent ?? (method == .get)
        self.destructive = destructive
    }
}

/// Lowest-level Instagram website transport. Implementations attach the user's session.
public protocol InstagramAPIClient: Sendable {
    func send(_ request: InstagramAPIRequest) async throws -> HTTPResponse
}

/// Instagram's own website client id, published in `instagram.com` page source as `APP_ID`.
/// This identifies the website, not a reverse-engineered iOS/Android app.
public enum InstagramWebConstants {
    public static let baseURL = URL(string: "https://www.instagram.com")!
    public static let webAppID = "936619743392459"
    public static let safariUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.139 Safari/537.36"
    public static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!
    public static let inboxReferer = URL(string: "https://www.instagram.com/direct/inbox/")!
}

/// Performs Instagram website requests with the locally stored user session.
/// Cookies/CSRF are read per request so a reconnect is picked up without rebuilding the client.
public struct InstagramHTTPClient: InstagramAPIClient {
    private let transport: HTTPTransport
    private let sessionProvider: @Sendable () throws -> InstagramWebSession?
    private let logger: AppLogger
    private let wwwClaim: InstagramWWWClaim

    public init(
        transport: HTTPTransport,
        sessionProvider: @escaping @Sendable () throws -> InstagramWebSession?,
        logger: AppLogger = .disabled
    ) {
        self.transport = transport
        self.sessionProvider = sessionProvider
        self.logger = logger.scoped("ig-web")
        self.wwwClaim = InstagramWWWClaim()
    }

    public func send(_ request: InstagramAPIRequest) async throws -> HTTPResponse {
        do {
            return try await perform(request)
        } catch IntegrationError.unexpectedResponse(code: let code) where code == 403 || code == 400 {
            try await Task.sleep(nanoseconds: 450_000_000)
            return try await perform(request)
        }
    }

    private func perform(_ request: InstagramAPIRequest) async throws -> HTTPResponse {
        guard let session = try sessionProvider(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        guard let csrf = session.csrfToken, !csrf.isEmpty else {
            throw IntegrationError.sessionExpired
        }

        let url: URL
        do {
            url = try Self.instagramURL(path: request.path, query: request.query)
        } catch let error as NetworkError {
            throw error.integrationError(destructive: request.destructive)
        }

        await warmupIfNeeded(session: session, csrf: csrf)

        var headers = apiHeaders(session: session, csrf: csrf)
        if request.method == .post {
            headers["Content-Type"] = Sensitive("application/x-www-form-urlencoded; charset=UTF-8")
        }

        let httpRequest = HTTPRequest(
            method: request.method,
            url: url,
            headers: headers,
            body: request.body,
            timeout: 30,
            isIdempotent: request.isIdempotent
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(httpRequest)
        } catch let error as NetworkError {
            throw error.integrationError(destructive: request.destructive)
        }

        logger.debug("\(request.method.rawValue) \(request.path) -> \(response.statusCode) keys=\(InstagramWebFormat.topKeys(response.body))")
        wwwClaim.update(from: response)
        try InstagramResponseClassifier.throwIfNeeded(response, destructive: request.destructive)
        return response
    }

    private func apiHeaders(session: InstagramWebSession, csrf: String) -> [String: Sensitive<String>] {
        var headers: [String: Sensitive<String>] = [
            "Cookie": session.cookieHeader(),
            "X-CSRFToken": Sensitive(csrf),
            "X-IG-App-ID": Sensitive(InstagramWebConstants.webAppID),
            "X-IG-WWW-Claim": Sensitive(wwwClaim.current()),
            "X-Requested-With": Sensitive("XMLHttpRequest"),
            "Referer": Sensitive(InstagramWebConstants.inboxReferer.absoluteString),
            "Origin": Sensitive(InstagramWebConstants.baseURL.absoluteString),
            "Accept": Sensitive("application/json"),
            "Accept-Language": Sensitive("en-US,en;q=0.9"),
            "User-Agent": Sensitive(InstagramWebConstants.safariUserAgent),
            "ig-u-ds-user-id": Sensitive(session.userID),
            "ig-intended-user-id": Sensitive(session.userID),
            "Sec-Fetch-Dest": Sensitive("empty"),
            "Sec-Fetch-Mode": Sensitive("cors"),
            "Sec-Fetch-Site": Sensitive("same-origin")
        ]
        if let asbd = wwwClaim.asbdID() {
            headers["X-ASBD-ID"] = Sensitive(asbd)
        }
        return headers
    }

    private func warmupIfNeeded(session: InstagramWebSession, csrf: String) async {
        guard wwwClaim.beginWarmup(for: session.userID) else { return }
        if let claim = session.wwwClaimCookie, !claim.isEmpty, claim != "0" {
            wwwClaim.seed(claim)
        }
        do {
            let url = try Self.instagramURL(path: "/direct/inbox/", query: [:])
            let request = HTTPRequest(
                method: .get,
                url: url,
                headers: [
                    "Cookie": session.cookieHeader(),
                    "X-CSRFToken": Sensitive(csrf),
                    "X-IG-App-ID": Sensitive(InstagramWebConstants.webAppID),
                    "User-Agent": Sensitive(InstagramWebConstants.safariUserAgent),
                    "Accept": Sensitive("text/html,application/xhtml+xml"),
                    "Accept-Language": Sensitive("en-US,en;q=0.9")
                ],
                timeout: 12,
                isIdempotent: true
            )
            let response = try await transport.send(request)
            wwwClaim.update(from: response)
            if let html = String(data: response.body, encoding: .utf8) {
                wwwClaim.applyPage(html)
            }
        } catch {
            logger.debug("inbox warmup skipped")
        }
    }

    /// Only relative paths on `www.instagram.com` over HTTPS. Absolute URLs are rejected so a
    /// malformed path cannot steer the client at another host.
    static func instagramURL(path: String, query: [String: String]) throws -> URL {
        let path = path.hasPrefix("/") ? path : "/" + path
        guard !path.contains("://"), !path.hasPrefix("//") else { throw NetworkError.invalidResponse }
        guard let relative = URL(string: path, relativeTo: InstagramWebConstants.baseURL) else {
            throw NetworkError.invalidResponse
        }
        guard var components = URLComponents(url: relative.absoluteURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw NetworkError.invalidResponse }
        let host = url.host?.lowercased()
        guard url.scheme?.lowercased() == "https", host == "www.instagram.com" || host == "instagram.com" else {
            throw NetworkError.insecureConnection
        }
        return url
    }
}

final class InstagramWWWClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "0"
    private var asbd: String?
    private var warmedForUser: String?

    func current() -> String { lock.withLock { value } }
    func asbdID() -> String? { lock.withLock { asbd } }

    func seed(_ claim: String) {
        lock.withLock {
            if value == "0", !claim.isEmpty { value = claim }
        }
    }

    func beginWarmup(for userID: String) -> Bool {
        lock.withLock {
            if warmedForUser == userID { return false }
            warmedForUser = userID
            asbd = nil
            value = "0"
            return true
        }
    }

    func applyPage(_ html: String) {
        if let match = html.range(of: "\"ASBD_ID\"\\s*:\\s*\"(\\d+)\"", options: .regularExpression) {
            let snippet = String(html[match])
            if let id = snippet.split(separator: "\"").last(where: { $0.allSatisfy(\.isNumber) }), !id.isEmpty {
                lock.withLock { asbd = String(id) }
            }
        }
        if let match = html.range(of: "\"www_claim\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
            let snippet = String(html[match])
            let parts = snippet.split(separator: "\"")
            if let claim = parts.last, !claim.isEmpty, claim != "0" {
                lock.withLock { value = String(claim) }
            }
        }
    }

    func update(from response: HTTPResponse) {
        guard let claim = response.header("x-ig-set-www-claim"), !claim.isEmpty else { return }
        lock.withLock { value = claim }
    }
}
