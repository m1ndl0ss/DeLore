#if DEBUG
import DeLoreCore
import Foundation

/// In-memory store for UI tests and previews. Compiled into Debug builds only; for manual
/// testing of real purchase flows use the StoreKit configuration file (App/StoreKit).
final class MockPurchaseService: PurchaseService, @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: PassLedger
    private var subscribed = false
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init(ledger: PassLedger) {
        self.ledger = ledger
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func products() async throws -> [StoreProduct] {
        [
            StoreProduct(id: "mock.pro.yearly", kind: .proYearly, displayName: "Pro Yearly", displayPrice: "$59.99", monthlyEquivalent: "$5.00"),
            StoreProduct(id: "mock.pro.monthly", kind: .proMonthly, displayName: "Pro Monthly", displayPrice: "$19.99", monthlyEquivalent: nil),
        ]
    }

    func purchase(_ productID: String) async throws -> PurchaseOutcome {
        if productID.contains("single") {
            _ = try ledger.credit(transactionID: UUID().uuidString)
        } else {
            lock.withLock { subscribed = true }
        }
        continuation.yield()
        return .purchased
    }

    func restore() async throws {
        continuation.yield()
    }

    func subscriptionStatus() async -> SubscriptionStatus {
        lock.withLock { subscribed }
            ? SubscriptionStatus(isActive: true, renewsOrExpiresAt: Date().addingTimeInterval(30 * 86_400))
            : .inactive
    }

    func transactionUpdates() -> AsyncStream<Void> { stream }
}
#endif
