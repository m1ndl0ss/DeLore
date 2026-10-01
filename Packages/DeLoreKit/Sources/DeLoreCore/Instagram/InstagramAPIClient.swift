import Foundation

public struct InstagramAPIRequest: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String]
    public var body: Sensitive<Data>?
    public var form: [String: String]
    public var host: String
    public var isIdempotent: Bool
    public var destructive: Bool

    public init(
        method: HTTPMethod,
        path: String,
        query: [String: String] = [:],
        body: Sensitive<Data>? = nil,
        form: [String: String] = [:],
        host: String = InstagramWebConstants.wwwHost,
        isIdempotent: Bool? = nil,
        destructive: Bool = false
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.form = form
        self.host = host
        self.isIdempotent = isIdempotent ?? (method == .get)
        self.destructive = destructive
    }
}

/// Lowest-level Instagram website transport. Implementations attach the user's session.
public protocol InstagramAPIClient: Sendable {
    func send(_ request: InstagramAPIRequest) async throws -> HTTPResponse
}

/// Remembers which Instagram host last served inbox/thread JSON so we don't retry the miss every page.
final class InstagramRequestHost: @unchecked Sendable {
    static let shared = InstagramRequestHost()
    private let lock = NSLock()
    private var preferred: String?

    func order() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let first = preferred ?? InstagramWebConstants.wwwHost
        let other = first == InstagramWebConstants.wwwHost
            ? InstagramWebConstants.apiHost
            : InstagramWebConstants.wwwHost
        return [first, other]
    }

    func remember(_ host: String) {
        lock.lock()
        preferred = host
        lock.unlock()
    }

    func reset() {
        lock.lock()
        preferred = nil
        lock.unlock()
    }
}

/// Instagram's own website client id, published in `instagram.com` page source as `APP_ID`.
/// This identifies the website, not a reverse-engineered iOS/Android app.
public enum InstagramWebConstants {
    public static let wwwHost = "www.instagram.com"
    public static let apiHost = "i.instagram.com"
    public static let baseURL = URL(string: "https://www.instagram.com")!
    public static let webAppID = "936619743392459"
    public static let safariUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.139 Safari/537.36"
    public static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!
    public static let inboxReferer = URL(string: "https://www.instagram.com/direct/inbox/")!
    public static let unsendDocID = "26948700068153789"
}

func fetchInstagramThread(
    client: InstagramAPIClient,
    id: String,
    cursor: String?,
    limit: Int = 20
) async throws -> InstagramWebFormat.ThreadPage {
    var query = ["limit": String(limit)]
    if let cursor {
        query["cursor"] = cursor
        query["direction"] = "older"
    }
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let path = "/api/v1/direct_v2/threads/\(encoded)/"
    var last: IntegrationError?
    for host in InstagramRequestHost.shared.order() {
        do {
            let response = try await client.send(
                InstagramAPIRequest(method: .get, path: path, query: query, host: host)
            )
            let page = try InstagramWebFormat.parseThread(response.body)
            InstagramRequestHost.shared.remember(host)
            return page
        } catch let error as IntegrationError {
            switch error {
            case .unexpectedResponse, .transportFailure:
                last = error
            default:
                throw error
            }
        } catch {
            last = .unexpectedResponse(code: 0)
        }
    }
    throw last ?? IntegrationError.unavailable
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
            url = try Self.instagramURL(path: request.path, query: request.query, host: request.host)
        } catch let error as NetworkError {
            throw error.integrationError(destructive: request.destructive)
        }

        await warmupIfNeeded(session: session, csrf: csrf)

        var headers = apiHeaders(session: session, csrf: csrf, host: request.host)
        if request.method == .post {
            headers["Content-Type"] = Sensitive("application/x-www-form-urlencoded; charset=UTF-8")
        }

        let body = graphqlForm(request, csrf: csrf)

        let httpRequest = HTTPRequest(
            method: request.method,
            url: url,
            headers: headers,
            body: body,
            timeout: 30,
            isIdempotent: request.isIdempotent
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(httpRequest)
        } catch let error as NetworkError {
            throw error.integrationError(destructive: request.destructive)
        }

        logger.debug("\(request.method.rawValue) \(request.host)\(request.path) -> \(response.statusCode) keys=\(InstagramWebFormat.topKeys(response.body))")
        wwwClaim.update(from: response)
        try InstagramResponseClassifier.throwIfNeeded(response, destructive: request.destructive)
        return response
    }

    private func apiHeaders(session: InstagramWebSession, csrf: String, host: String) -> [String: Sensitive<String>] {
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
            "Sec-Fetch-Site": Sensitive(host == InstagramWebConstants.apiHost ? "same-site" : "same-origin")
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

    /// Only relative paths on Instagram's own HTTPS hosts. Absolute URLs are rejected so a
    /// malformed path cannot steer the client at another host.
    static func instagramURL(path: String, query: [String: String], host: String = InstagramWebConstants.wwwHost) throws -> URL {
        let path = path.hasPrefix("/") ? path : "/" + path
        guard !path.contains("://"), !path.hasPrefix("//") else { throw NetworkError.invalidResponse }
        let requested = host.lowercased()
        let allowed: Set<String> = [InstagramWebConstants.wwwHost, "instagram.com", InstagramWebConstants.apiHost]
        guard allowed.contains(requested) else { throw NetworkError.insecureConnection }
        guard let base = URL(string: "https://\(requested)") else { throw NetworkError.invalidResponse }
        guard let relative = URL(string: path, relativeTo: base) else {
            throw NetworkError.invalidResponse
        }
        guard var components = URLComponents(url: relative.absoluteURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw NetworkError.invalidResponse }
        guard url.scheme?.lowercased() == "https",
              let resolvedHost = url.host?.lowercased(),
              allowed.contains(resolvedHost) else {
            throw NetworkError.insecureConnection
        }
        return url
    }

    static func encodeForm(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = fields.map { key, value in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? key
            let item = value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
            return "\(name)=\(item)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func formBody(_ form: [String: String], csrf: String, destructive: Bool) -> Sensitive<Data>? {
        if form.isEmpty && !destructive { return nil }
        var fields = form
        if fields["csrftoken"] == nil && fields["_csrftoken"] == nil {
            fields["_csrftoken"] = csrf
        }
        return Sensitive(encodeForm(fields))
    }

    private func graphqlForm(_ request: InstagramAPIRequest, csrf: String) -> Sensitive<Data>? {
        if let body = request.body { return body }
        var form = request.form
        if request.path.contains("graphql") {
            if form["fb_dtsg"] == nil, let dtsg = wwwClaim.fbDtsg(), !dtsg.isEmpty {
                form["fb_dtsg"] = dtsg
                form["jazoest"] = "2" + String(dtsg.unicodeScalars.reduce(0) { $0 + Int($1.value) })
            }
            if form["lsd"] == nil, let lsd = wwwClaim.lsdToken(), !lsd.isEmpty {
                form["lsd"] = lsd
            }
        }
        return Self.formBody(form, csrf: csrf, destructive: request.destructive)
    }
}

final class InstagramWWWClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "0"
    private var asbd: String?
    private var dtsg: String?
    private var lsd: String?
    private var warmedForUser: String?

    func current() -> String { lock.withLock { value } }
    func asbdID() -> String? { lock.withLock { asbd } }
    func fbDtsg() -> String? { lock.withLock { dtsg } }
    func lsdToken() -> String? { lock.withLock { lsd } }

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
            dtsg = nil
            lsd = nil
            value = "0"
            InstagramRequestHost.shared.reset()
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
        let decoded = html.replacingOccurrences(of: "\\u0022", with: "\"")
        if let token = firstMatch(decoded, pattern: "DTSGInitialData[\\s\\S]{0,400}?\"token\"\\s*:\\s*\"([^\"]+)\"")
            ?? firstMatch(decoded, pattern: "DTSGInitData[\\s\\S]{0,400}?\"token\"\\s*:\\s*\"([^\"]+)\"")
            ?? firstMatch(decoded, pattern: "\"dtsg\"\\s*:\\s*\\{\\s*\"token\"\\s*:\\s*\"([^\"]+)\"") {
            lock.withLock { dtsg = token }
        }
        if let token = firstMatch(decoded, pattern: "\"LSD\"[\\s\\S]{0,200}?\"token\"\\s*:\\s*\"([^\"]+)\"") {
            lock.withLock { lsd = token }
        }
    }

    private func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let tokenRange = Range(match.range(at: 1), in: text) else { return nil }
        let token = String(text[tokenRange])
        return token.isEmpty ? nil : token
    }

    func update(from response: HTTPResponse) {
        guard let claim = response.header("x-ig-set-www-claim"), !claim.isEmpty else { return }
        lock.withLock { value = claim }
    }
}
