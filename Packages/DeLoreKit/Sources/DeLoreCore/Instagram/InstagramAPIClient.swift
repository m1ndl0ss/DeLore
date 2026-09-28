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
    public static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
    public static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!
    public static let inboxReferer = URL(string: "https://www.instagram.com/direct/inbox/")!
}

/// Performs Instagram website requests with the locally stored user session.
/// Cookies/CSRF are read per request so a reconnect is picked up without rebuilding the client.
public struct InstagramHTTPClient: InstagramAPIClient {
    private let transport: HTTPTransport
    private let sessionProvider: @Sendable () throws -> InstagramWebSession?
    private let logger: AppLogger

    public init(
        transport: HTTPTransport,
        sessionProvider: @escaping @Sendable () throws -> InstagramWebSession?,
        logger: AppLogger = .disabled
    ) {
        self.transport = transport
        self.sessionProvider = sessionProvider
        self.logger = logger.scoped("ig-web")
    }

    public func send(_ request: InstagramAPIRequest) async throws -> HTTPResponse {
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

        var headers: [String: Sensitive<String>] = [
            "Cookie": session.cookieHeader(),
            "X-CSRFToken": Sensitive(csrf),
            "X-IG-App-ID": Sensitive(InstagramWebConstants.webAppID),
            "X-Requested-With": Sensitive("XMLHttpRequest"),
            "Referer": Sensitive(InstagramWebConstants.inboxReferer.absoluteString),
            "Origin": Sensitive(InstagramWebConstants.baseURL.absoluteString),
            "Accept": Sensitive("application/json"),
            "User-Agent": Sensitive(InstagramWebConstants.safariUserAgent)
        ]
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

        logger.debug("\(request.method.rawValue) instagram.com -> \(response.statusCode)")
        try InstagramResponseClassifier.throwIfNeeded(response, destructive: request.destructive)
        return response
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
