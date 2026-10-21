import DeLoreCore
import Foundation

struct StoreProduct: Identifiable, Equatable, Sendable {
    enum Kind: Sendable, Equatable {
        case oneTimeCleanup
        case proMonthly
        case proYearly
    }

    let id: String
    let kind: Kind
    let displayName: String
    let displayPrice: String
    /// Localized price per month for yearly plans, when StoreKit can compute it.
    let monthlyEquivalent: String?
    /// Hidden 10% SKU. Paywall lists the normal plan and checks this out after a code.
    let isPromo: Bool
}

enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    /// Waiting on Ask to Buy or payment approval.
    case pending
    case cancelled
}

enum PurchaseError: Error, Equatable {
    case storeUnavailable
    case productNotFound
    case verificationFailed
}

struct SubscriptionStatus: Equatable, Sendable {
    var isActive: Bool
    var renewsOrExpiresAt: Date?

    static let inactive = SubscriptionStatus(isActive: false, renewsOrExpiresAt: nil)
}

/// Abstraction over StoreKit so the app can run against a mock in UI tests.
protocol PurchaseService: Sendable {
    func products() async throws -> [StoreProduct]
    func purchase(_ productID: String) async throws -> PurchaseOutcome
    /// Syncs with the App Store. Only call in response to the user tapping restore.
    func restore() async throws
    func subscriptionStatus() async -> SubscriptionStatus
    /// Emits whenever a transaction arrives outside a purchase call (renewals, Ask to Buy…).
    func transactionUpdates() -> AsyncStream<Void>
}

/// Unused one-time passes and the free allowance, kept in the Keychain so they survive
/// reinstalls and aren't trivially editable.
///
/// Free usage is per Instagram account, kept locally and max-merged with the Retract worker
/// so the same account shares one counter across devices. Never cleared on logout.
struct PassLedger: Sendable {
    static let passesKey = "entitlements.passes"
    static let processedKey = "entitlements.processedTransactions"
    /// Legacy device-wide counter; migrated into `freeUsedByAccountKey` on first account touch.
    static let freeUsedKey = "entitlements.freeUsed"
    static let freeUsedByAccountKey = "entitlements.freeUsedByAccount"
    static let preservedKeys = [passesKey, processedKey, freeUsedKey, freeUsedByAccountKey]

    let store: SecretStore

    var passes: Int { integer(for: Self.passesKey) }

    /// Free usage for a signed-in Instagram account. Nil / empty → 0.
    func freeMessagesUsed(for userID: String?) -> Int {
        guard let userID = normalized(userID) else { return 0 }
        migrateLegacyIfNeeded(into: userID)
        return usageByAccount()[userID] ?? 0
    }

    private func integer(for key: String) -> Int {
        guard let value = try? store.string(for: key) else { return 0 }
        return Int(value) ?? 0
    }

    /// Credits a pass exactly once per transaction id.
    func credit(transactionID: String) throws -> Bool {
        var processed = processedTransactions
        guard processed.insert(transactionID).inserted else { return false }
        try store.set(String(passes + 1), for: Self.passesKey)
        try store.set(JSONEncoder().encode(processed), for: Self.processedKey)
        return true
    }

    func consumePass() throws -> Bool {
        let current = passes
        guard current > 0 else { return false }
        try store.set(String(current - 1), for: Self.passesKey)
        return true
    }

    func addFreeUsage(_ count: Int, accountUserID: String?) throws {
        guard count > 0, let userID = normalized(accountUserID) else { return }
        migrateLegacyIfNeeded(into: userID)
        var map = usageByAccount()
        map[userID, default: 0] += count
        try store.set(JSONEncoder().encode(map), for: Self.freeUsedByAccountKey)
    }

    /// Raises local usage to at least `remote` for this account (cross-device max-merge).
    @discardableResult
    func mergeRemoteFreeUsage(_ remote: Int, accountUserID: String?) throws -> Int {
        guard let userID = normalized(accountUserID) else { return 0 }
        migrateLegacyIfNeeded(into: userID)
        var map = usageByAccount()
        let merged = max(map[userID] ?? 0, max(0, remote))
        map[userID] = merged
        try store.set(JSONEncoder().encode(map), for: Self.freeUsedByAccountKey)
        return merged
    }

    private func normalized(_ userID: String?) -> String? {
        let value = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func usageByAccount() -> [String: Int] {
        guard let data = try? store.data(for: Self.freeUsedByAccountKey),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }

    /// One-time: fold the old device-wide integer into this account, then drop the legacy key.
    private func migrateLegacyIfNeeded(into userID: String) {
        let legacy = integer(for: Self.freeUsedKey)
        guard legacy > 0 else { return }
        var map = usageByAccount()
        if map[userID] == nil {
            map[userID] = legacy
            try? store.set(JSONEncoder().encode(map), for: Self.freeUsedByAccountKey)
        }
        try? store.removeValue(for: Self.freeUsedKey)
    }

    private var processedTransactions: Set<String> {
        guard let data = try? store.data(for: Self.processedKey) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }
}
