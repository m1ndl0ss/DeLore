import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info
    case warning
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Destination for log lines. Receives already-redacted text only.
public protocol LogSink: Sendable {
    func write(level: LogLevel, category: String, message: String)
}

public struct NullLogSink: LogSink {
    public init() {}
    public func write(level: LogLevel, category: String, message: String) {}
}

/// Collects lines in memory. Used by tests to assert nothing sensitive is written.
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public func write(level: LogLevel, category: String, message: String) {
        lock.withLock { storage.append("[\(category)] \(message)") }
    }

    public var lines: [String] { lock.withLock { storage } }
}

/// App logger. Every message passes through `Redactor` regardless of sink, and messages
/// below `minimumLevel` are dropped before formatting side effects matter.
public struct AppLogger: Sendable {
    public let category: String
    private let sink: LogSink
    private let minimumLevel: LogLevel

    public init(category: String, sink: LogSink, minimumLevel: LogLevel) {
        self.category = category
        self.sink = sink
        self.minimumLevel = minimumLevel
    }

    public static let disabled = AppLogger(category: "none", sink: NullLogSink(), minimumLevel: .error)

    public func scoped(_ category: String) -> AppLogger {
        AppLogger(category: category, sink: sink, minimumLevel: minimumLevel)
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }

    private func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        sink.write(level: level, category: category, message: Redactor.redact(message()))
    }
}

extension Error {
    /// A description safe to log: type and case only, redacted.
    public var safeDescription: String {
        if let integration = self as? IntegrationError { return "IntegrationError.\(integration.caseName)" }
        return Redactor.redact(String(describing: type(of: self)))
    }
}

extension IntegrationError {
    public var caseName: String {
        switch self {
        case .rateLimited: return "rateLimited"
        case .sessionExpired: return "sessionExpired"
        case .verificationRequired: return "verificationRequired"
        case .offline: return "offline"
        case .transportFailure: return "transportFailure"
        case .serverUnavailable: return "serverUnavailable"
        case let .unexpectedResponse(code): return "unexpectedResponse(\(code.map(String.init) ?? "-"))"
        case .unavailable: return "unavailable"
        }
    }
}
