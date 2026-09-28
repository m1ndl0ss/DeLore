import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var url: URL
    /// Header values are wrapped so they can't end up in logs or error descriptions.
    public var headers: [String: Sensitive<String>]
    public var body: Sensitive<Data>?
    public var timeout: TimeInterval
    /// Only idempotent requests are ever retried by the transport layer.
    public var isIdempotent: Bool

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: Sensitive<String>] = [:],
        body: Sensitive<Data>? = nil,
        timeout: TimeInterval = 30,
        isIdempotent: Bool? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.isIdempotent = isIdempotent ?? (method == .get)
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum NetworkError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case cancelled
    case connectionLost
    case insecureConnection
    case invalidResponse
    case decodingFailed
    case status(Int, retryAfter: TimeInterval?)
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession transport with an ephemeral session: no URL cache, no shared cookie jar, no
/// credential storage. TLS validation is the system default; we don't pin, because pinning
/// a third-party platform's rotating certificates would break the app without adding safety.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            #if canImport(Darwin)
            config.waitsForConnectivity = false
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            #endif
            return config
        }()
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw NetworkError.insecureConnection }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers { urlRequest.setValue(value.value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body?.value

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: NetworkError.invalidResponse)
                        return
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let key = key as? String, let value = value as? String { headers[key] = value }
                    }
                    continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, headers: headers, body: data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func map(_ error: Error) -> NetworkError {
        guard let urlError = error as? URLError else { return .connectionLost }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed:
            return .offline
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .insecureConnection
        default: return .connectionLost
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Retry policy for idempotent requests only. Destructive requests are never retried here.
public struct TransportRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 20) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
}

/// Adds status handling and bounded retries for idempotent requests.
public struct HTTPClient: Sendable {
    private let transport: HTTPTransport
    private let retry: TransportRetryPolicy
    private let clock: EngineClock
    private let random: RandomSource
    private let logger: AppLogger

    public init(
        transport: HTTPTransport,
        retry: TransportRetryPolicy = TransportRetryPolicy(),
        clock: EngineClock = SystemClock(),
        random: RandomSource = SystemRandom(),
        logger: AppLogger = .disabled
    ) {
        self.transport = transport
        self.retry = retry
        self.clock = clock
        self.random = random
        self.logger = logger.scoped("http")
    }

    /// Sends a request and returns responses in 200..<300. Other statuses throw `.status`.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let response = try await transport.send(request)
                if (200..<300).contains(response.statusCode) { return response }
                let retryAfter = response.header("Retry-After").flatMap(TimeInterval.init)
                throw NetworkError.status(response.statusCode, retryAfter: retryAfter)
            } catch let error as NetworkError {
                // Host + path only; query strings and headers are never logged.
                logger.debug("\(request.method.rawValue) \(request.url.host ?? "-") failed: \(error)")
                guard request.isIdempotent, attempt < retry.maxAttempts, Self.isRetryable(error) else { throw error }
                let delay = min(retry.maxDelay, retry.baseDelay * pow(2, Double(attempt - 1))) * (0.5 + 0.5 * random.nextUnit())
                try await clock.sleep(for: delay)
            }
        }
    }

    public func send<Response: Decodable>(_ request: HTTPRequest, decoding type: Response.Type) async throws -> Response {
        let response = try await send(request)
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw NetworkError.decodingFailed
        }
    }

    static func isRetryable(_ error: NetworkError) -> Bool {
        switch error {
        case .timedOut, .connectionLost: return true
        case let .status(code, _): return code >= 500
        case .offline, .cancelled, .insecureConnection, .invalidResponse, .decodingFailed: return false
        }
    }
}

extension NetworkError {
    /// Maps transport errors onto the integration vocabulary the engine understands.
    /// Platform-specific signals (checkpoint bodies etc.) are layered on by each integration.
    public func integrationError(destructive: Bool) -> IntegrationError {
        switch self {
        case .offline: return .offline
        case .timedOut, .connectionLost, .cancelled:
            return .transportFailure(requestMayHaveBeenApplied: destructive)
        case .insecureConnection: return .transportFailure(requestMayHaveBeenApplied: false)
        case .invalidResponse, .decodingFailed: return .unexpectedResponse(code: nil)
        case let .status(code, retryAfter):
            switch code {
            case 401: return .sessionExpired
            case 429: return .rateLimited(retryAfter: retryAfter)
            case 500...599: return .serverUnavailable
            default: return .unexpectedResponse(code: code)
            }
        }
    }
}
