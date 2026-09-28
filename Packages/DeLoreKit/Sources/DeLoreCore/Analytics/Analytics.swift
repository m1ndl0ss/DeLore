import Foundation

/// Product analytics events. The payload vocabulary is closed: every property value comes
/// from an enum or a coarse bucket, so no user content or identifier can be attached.
public enum AnalyticsEvent: Equatable, Sendable {
    case onboardingStarted
    case onboardingCompleted
    case importStarted
    case importCompleted(size: SizeBucket)
    case importFailed(reason: FailureCategory)
    case cleanupStarted(scope: ScopeKind, size: SizeBucket, usesFilters: Bool)
    case cleanupPaused(reason: PauseCategory)
    case cleanupResumed
    case cleanupCompleted(size: SizeBucket)
    case cleanupCancelled
    case cleanupFailed(reason: PauseCategory)
    case paywallShown(context: PaywallContext)
    case purchaseStarted(product: ProductKind)
    case purchaseCompleted(product: ProductKind)
    case subscriptionStarted
    case restoreCompleted
    case dataErased

    public enum ScopeKind: String, Sendable { case everything, selected, single }
    public enum FailureCategory: String, Sendable { case unreadable, noMessages, unsupported, cancelled }
    public enum PaywallContext: String, Sendable { case limit, filters, settings }
    public enum ProductKind: String, Sendable { case oneTime, proMonthly, proYearly }

    public enum PauseCategory: String, Sendable {
        case user, background, interrupted, rateLimited, sessionExpired, verification, failures, offline, unexpected, unavailable, storage

        public init(_ reason: PauseReason) {
            switch reason {
            case .user: self = .user
            case .appInBackground: self = .background
            case .interrupted: self = .interrupted
            case .rateLimited: self = .rateLimited
            case .sessionExpired: self = .sessionExpired
            case .verificationRequired: self = .verification
            case .repeatedFailures: self = .failures
            case .offline: self = .offline
            case .unexpectedResponse: self = .unexpected
            case .integrationUnavailable: self = .unavailable
            case .storageFailure: self = .storage
            }
        }
    }

    /// Coarse size buckets instead of exact counts.
    public enum SizeBucket: String, Sendable {
        case none = "0", tiny = "1-49", small = "50-499", medium = "500-4999", large = "5000+"

        public init(count: Int) {
            switch count {
            case ..<1: self = .none
            case 1..<50: self = .tiny
            case 50..<500: self = .small
            case 500..<5_000: self = .medium
            default: self = .large
            }
        }
    }

    public var name: String {
        switch self {
        case .onboardingStarted: return "onboarding_started"
        case .onboardingCompleted: return "onboarding_completed"
        case .importStarted: return "import_started"
        case .importCompleted: return "import_completed"
        case .importFailed: return "import_failed"
        case .cleanupStarted: return "cleanup_started"
        case .cleanupPaused: return "cleanup_paused"
        case .cleanupResumed: return "cleanup_resumed"
        case .cleanupCompleted: return "cleanup_completed"
        case .cleanupCancelled: return "cleanup_cancelled"
        case .cleanupFailed: return "cleanup_failed"
        case .paywallShown: return "paywall_shown"
        case .purchaseStarted: return "purchase_started"
        case .purchaseCompleted: return "purchase_completed"
        case .subscriptionStarted: return "subscription_started"
        case .restoreCompleted: return "restore_completed"
        case .dataErased: return "data_erased"
        }
    }

    public var properties: [String: String] {
        switch self {
        case let .importCompleted(size), let .cleanupCompleted(size):
            return ["size": size.rawValue]
        case let .importFailed(reason):
            return ["reason": reason.rawValue]
        case let .cleanupStarted(scope, size, usesFilters):
            return ["scope": scope.rawValue, "size": size.rawValue, "filters": usesFilters ? "yes" : "no"]
        case let .cleanupPaused(reason), let .cleanupFailed(reason):
            return ["reason": reason.rawValue]
        case let .paywallShown(context):
            return ["context": context.rawValue]
        case let .purchaseStarted(product), let .purchaseCompleted(product):
            return ["product": product.rawValue]
        case .onboardingStarted, .onboardingCompleted, .importStarted, .cleanupResumed, .cleanupCancelled,
             .subscriptionStarted, .restoreCompleted, .dataErased:
            return [:]
        }
    }
}

public struct AnalyticsPayload: Equatable, Sendable {
    public let name: String
    public let properties: [String: String]
}

/// Backend-agnostic delivery. No third-party SDK ships by default.
public protocol AnalyticsSink: Sendable {
    func send(_ payload: AnalyticsPayload)
}

public struct NoopAnalyticsSink: AnalyticsSink {
    public init() {}
    public func send(_ payload: AnalyticsPayload) {}
}

public final class RecordingAnalyticsSink: AnalyticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AnalyticsPayload] = []

    public init() {}

    public func send(_ payload: AnalyticsPayload) {
        lock.withLock { storage.append(payload) }
    }

    public var payloads: [AnalyticsPayload] { lock.withLock { storage } }
}

public struct Analytics: Sendable {
    private let sink: AnalyticsSink
    private let isEnabled: Bool

    public init(sink: AnalyticsSink, isEnabled: Bool) {
        self.sink = sink
        self.isEnabled = isEnabled
    }

    public static let disabled = Analytics(sink: NoopAnalyticsSink(), isEnabled: false)

    /// Only lowercase snake_case names and short enum-like values pass. Anything else is dropped.
    /// Runs of 5+ digits are rejected so identifiers and exact counts can't slip through.
    public static func isSafe(_ payload: AnalyticsPayload) -> Bool {
        func safeToken(_ value: String) -> Bool {
            guard !value.isEmpty, value.count <= 24,
                  value.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || "_-+".contains($0)) }) else { return false }
            var digitRun = 0
            for character in value {
                digitRun = character.isNumber ? digitRun + 1 : 0
                if digitRun >= 5 { return false }
            }
            return true
        }
        return safeToken(payload.name) && payload.properties.allSatisfy { safeToken($0.key) && safeToken($0.value) }
    }

    public func track(_ event: AnalyticsEvent) {
        guard isEnabled else { return }
        let payload = AnalyticsPayload(name: event.name, properties: event.properties)
        guard Analytics.isSafe(payload) else { return }
        sink.send(payload)
    }
}
