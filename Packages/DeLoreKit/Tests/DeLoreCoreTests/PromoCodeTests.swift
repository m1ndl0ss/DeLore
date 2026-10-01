@testable import DeLoreCore
import Foundation
import XCTest

final class PromoCodeTests: XCTestCase {
    func testComplimentaryCodeIsCaseInsensitive() {
        XCTAssertEqual(PromoCatalog.offer(for: "kandal24"), .complimentary)
        XCTAssertEqual(PromoCatalog.offer(for: "  KANDAL24  "), .complimentary)
    }

    func testUnknownCodeIsRejected() {
        XCTAssertNil(PromoCatalog.offer(for: "NOPE"))
        XCTAssertNil(PromoCatalog.offer(for: " "))
    }

    func testCheckoutIDUsesPromoSku() {
        let catalog = ProductCatalog(
            oneTimeCleanup: "app.delore.cleanup.single",
            proMonthly: "app.delore.pro.monthly",
            proYearly: "app.delore.pro.yearly"
        )
        XCTAssertEqual(catalog.checkoutID(forDisplay: "app.delore.pro.yearly", discounted: false), "app.delore.pro.yearly")
        XCTAssertEqual(catalog.checkoutID(forDisplay: "app.delore.pro.yearly", discounted: true), "app.delore.pro.yearly.promo")
        XCTAssertEqual(catalog.all.count, 5)
    }

    func testCampaignCodesAreTenPercentOff() {
        XCTAssertEqual(PromoCatalog.offer(for: "RETRACT10"), .percentOff(10))
        XCTAssertEqual(PromoCatalog.offer(for: "ref10"), .percentOff(10))
        XCTAssertEqual(PromoCatalog.percentOffCodes, ["RETRACT10", "REF10"])
    }

    func testDiscountedPriceKeepsCurrency() {
        XCTAssertEqual(PromoVault.discountedPrice("$59.99", percentOff: 10), "$53.99")
        XCTAssertEqual(PromoVault.discountedPrice("$19.99", percentOff: 10), "$17.99")
    }

    func testFailedGuessesLockAfterThree() {
        let vault = PromoVault(store: InMemorySecretStore())
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        XCTAssertEqual(vault.redeem("WRONG1", now: now), .invalid(remaining: 2))
        XCTAssertEqual(vault.redeem("WRONG2", now: now), .invalid(remaining: 1))
        XCTAssertEqual(vault.redeem("WRONG3", now: now), .invalid(remaining: 0))
        XCTAssertEqual(vault.redeem("KANDAL24", now: now), .locked)
        XCTAssertTrue(vault.isLocked(now: now))
    }

    func testEmptyGuessDoesNotCount() {
        let vault = PromoVault(store: InMemorySecretStore())
        XCTAssertEqual(vault.redeem("   "), .empty)
        XCTAssertEqual(vault.remainingGuesses(), PromoVault.dailyLimit)
    }

    func testComplimentaryPersistsAndUnlocks() {
        let store = InMemorySecretStore()
        let vault = PromoVault(store: store)
        XCTAssertEqual(vault.redeem("KANDAL24"), .applied(.complimentary))
        XCTAssertTrue(PromoVault(store: store).isComplimentary)
        XCTAssertEqual(PromoVault(store: store).appliedCode, "KANDAL24")
    }

    func testGuessesResetNextDay() {
        let vault = PromoVault(store: InMemorySecretStore())
        let day1 = Date(timeIntervalSince1970: 1_775_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        _ = vault.redeem("A", now: day1)
        _ = vault.redeem("B", now: day1)
        _ = vault.redeem("C", now: day1)
        XCTAssertEqual(vault.redeem("KANDAL24", now: day2), .applied(.complimentary))
    }

    func testPercentOffPersists() {
        let store = InMemorySecretStore()
        let vault = PromoVault(store: store)
        XCTAssertEqual(vault.redeem("ref10"), .applied(.percentOff(10)))
        XCTAssertEqual(PromoVault(store: store).percentOff, 10)
        XCTAssertFalse(PromoVault(store: store).isComplimentary)
        XCTAssertEqual(PromoVault(store: store).appliedCode, "REF10")
    }
}
