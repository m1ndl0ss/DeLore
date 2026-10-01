@testable import DeLore
import DeLoreCore
import XCTest

final class CleanupCopyTests: XCTestCase {
    private let allReasons: [PauseReason] = [
        .user, .appInBackground, .interrupted, .rateLimited, .sessionExpired, .verificationRequired,
        .repeatedFailures, .offline, .unexpectedResponse, .integrationUnavailable, .storageFailure
    ]

    func testEveryPauseReasonHasHumanCopy() {
        let jargon = ["api", "429", "401", "403", "token", "endpoint", "http", "checkpoint", "error code", "session id", "cookie", "json"]
        for reason in allReasons {
            let copy = CleanupStatusCopy.copy(for: reason)
            XCTAssertFalse(copy.headline.isEmpty)
            let text = (copy.headline + " " + (copy.message ?? "")).lowercased()
            for term in jargon {
                XCTAssertFalse(text.contains(term), "\(reason) copy uses jargon: \(term)")
            }
            XCTAssertFalse(text.contains("bypass"), "never suggest bypassing a safety check")
        }
    }

    func testSecurityPausesRequireUserAction() {
        XCTAssertEqual(CleanupStatusCopy.copy(for: .verificationRequired).action, .resumeAfterVerifying)
        XCTAssertEqual(CleanupStatusCopy.copy(for: .sessionExpired).action, .reconnect)
        XCTAssertEqual(CleanupStatusCopy.copy(for: .integrationUnavailable).action, .none)
    }

    func testCooldownCopyWhileRunning() {
        let copy = CleanupStatusCopy.make(for: .running, coolingDownUntil: Date().addingTimeInterval(600))
        XCTAssertEqual(copy.tone, .caution)
        XCTAssertEqual(copy.action, .pause)
        XCTAssertTrue(copy.headline.lowercased().contains("wait"))
    }

    func testTimeRemainingIsHonest() {
        XCTAssertTrue(TimeRemainingCopy.text(for: nil).contains("Working out"))
        XCTAssertEqual(TimeRemainingCopy.text(for: 20), "Less than a minute left")
        XCTAssertTrue(TimeRemainingCopy.text(for: 4 * 3_600 + 60).contains("4 hours"))
    }
}

final class PassLedgerTests: XCTestCase {
    func testPassIsCreditedOncePerTransaction() throws {
        let ledger = PassLedger(store: InMemorySecretStore())
        XCTAssertTrue(try ledger.credit(transactionID: "t1"))
        XCTAssertFalse(try ledger.credit(transactionID: "t1"))
        XCTAssertTrue(try ledger.credit(transactionID: "t2"))
        XCTAssertEqual(ledger.passes, 2)
        XCTAssertTrue(try ledger.consumePass())
        XCTAssertEqual(ledger.passes, 1)
    }

    func testFreeUsageAccumulates() throws {
        let ledger = PassLedger(store: InMemorySecretStore())
        try ledger.addFreeUsage(20)
        try ledger.addFreeUsage(5)
        XCTAssertEqual(ledger.freeMessagesUsed, 25)
    }

    func testConsumingWithoutPassFails() throws {
        XCTAssertFalse(try PassLedger(store: InMemorySecretStore()).consumePass())
    }
}

@MainActor
final class EntitlementManagerTests: XCTestCase {
    func testPaywallOnlyOffersSubscriptions() async throws {
        let ledger = PassLedger(store: InMemorySecretStore())
        let manager = EntitlementManager(service: MockPurchaseService(ledger: ledger), ledger: ledger, freeLimit: 50, analytics: .disabled)
        await manager.loadProducts()
        XCTAssertFalse(manager.products.contains { $0.kind == .oneTimeCleanup })
        let yearly = try XCTUnwrap(manager.products.first { $0.kind == .proYearly })
        _ = await manager.purchase(yearly)
        XCTAssertTrue(manager.isPro)
    }

    func testExistingPassStillUnlocksACleanup() async throws {
        let ledger = PassLedger(store: InMemorySecretStore())
        XCTAssertTrue(try ledger.credit(transactionID: "legacy-pass"))
        let manager = EntitlementManager(service: MockPurchaseService(ledger: ledger), ledger: ledger, freeLimit: 50, analytics: .disabled)
        await manager.refresh()
        XCTAssertEqual(manager.state.cleanupPasses, 1)
        XCTAssertEqual(manager.allowance(requestedCount: 9_000, usesAdvancedFilters: false), .allowed(limit: nil, consumesPass: true, usesFreeAllowance: false))
        XCTAssertTrue(manager.consumePass())
        XCTAssertEqual(manager.state.cleanupPasses, 0)
    }

    func testFreeTierIsLimited() {
        let ledger = PassLedger(store: InMemorySecretStore())
        let manager = EntitlementManager(service: MockPurchaseService(ledger: ledger), ledger: ledger, freeLimit: 100, analytics: .disabled)
        XCTAssertEqual(manager.allowance(requestedCount: 200, usesAdvancedFilters: false), .limited(remainingFree: 100))
        manager.recordFreeUsage(30)
        XCTAssertEqual(manager.remainingFree, 70)
    }

    func testComplimentaryPromoUnlocksProWithoutStore() async {
        let ledger = PassLedger(store: InMemorySecretStore())
        let manager = EntitlementManager(service: MockPurchaseService(ledger: ledger), ledger: ledger, freeLimit: 100, analytics: .disabled)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(manager.redeemPromo("kandal24"), .applied(.complimentary))
        XCTAssertTrue(manager.isPro)
        await manager.refresh()
        XCTAssertTrue(manager.isPro, "store refresh must not strip complimentary Pro")
    }
}

final class ConfigurationTests: XCTestCase {
    func testConfigurationLoadsFromBundle() {
        let configuration = AppConfiguration.load()
        XCTAssertFalse(configuration.products.oneTimeCleanup.isEmpty)
        XCTAssertEqual(Set(configuration.products.all).count, 3)
        XCTAssertEqual(configuration.freeCleanupLimit, 100)
        XCTAssertEqual(configuration.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(configuration.privacyPolicyURL.scheme, "https")
        XCTAssertFalse(configuration.analyticsEnabled, "no analytics without a vetted backend")
    }

    func testProductionPacingIsConservative() {
        let policy = AppConfiguration.load().ratePolicy
        XCTAssertGreaterThanOrEqual(policy.minimumDelay, 3)
        XCTAssertLessThanOrEqual(policy.hourlyLimit, 400)
        XCTAssertLessThanOrEqual(policy.maxAttemptsPerItem, 3)
    }

    func testLiveUnsendUsesWebsiteSession() {
        let service = LiveIntegration.makeUnsendService(sessionVault: SessionVault(store: InMemorySecretStore()), logger: .disabled)
        XCTAssertTrue(service is InstagramWebUnsendService)
        XCTAssertFalse(service is UnavailableUnsendService)
    }
}
