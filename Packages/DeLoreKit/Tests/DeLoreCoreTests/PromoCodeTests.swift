import XCTest
@testable import DeLoreCore

final class PromoCodeTests: XCTestCase {
    func testUnknownCodesAreRejected() {
        XCTAssertNil(PromoCatalog.offer(for: "KANDAL24"))
        XCTAssertNil(PromoCatalog.offer(for: "NOPE"))
        XCTAssertNil(PromoCatalog.offer(for: " "))
    }

    func testCampaignCodesAreTenPercentOff() {
        XCTAssertEqual(PromoCatalog.offer(for: "RETRACT10"), .percentOff(10))
        XCTAssertEqual(PromoCatalog.offer(for: "ref10"), .percentOff(10))
        XCTAssertEqual(PromoCatalog.bakedPercentOffCodes, ["RETRACT10", "REF10"])
    }

    func testRemotePayloadParsesComplimentaryUsernames() {
        let data = Data(#"{"percentOff":10,"codes":["NEWCODE","retract10"],"complimentaryUsernames":["Alice","@Bob"]}"#.utf8)
        let parsed = RemotePromoCatalog.parse(data)
        XCTAssertEqual(parsed?.codes, ["NEWCODE", "RETRACT10"])
        XCTAssertEqual(parsed?.percent, 10)
        XCTAssertEqual(parsed?.usernames, ["alice", "bob"])
    }

    func testCampaignBookCachesRemoteCodesAndAllowlist() {
        let store = InMemorySecretStore()
        let book = PromoCampaignBook(store: store)
        XCTAssertTrue(book.replaceCampaign(codes: ["FRIEND10", "VIP10"], percentOff: 10, complimentaryUsernames: ["matvey"]))
        XCTAssertEqual(book.offer(for: "friend10"), .percentOff(10))
        XCTAssertNil(book.offer(for: "RETRACT10"), "remote replace drops baked codes not in the new list")
        XCTAssertTrue(book.isComplimentaryUsername("Matvey"))
        let reloaded = PromoCampaignBook(store: store)
        XCTAssertEqual(reloaded.offer(for: "VIP10"), .percentOff(10))
        XCTAssertTrue(reloaded.isComplimentaryUsername("matvey"))
    }

    func testDiscountedPriceFormatting() {
        XCTAssertEqual(PromoVault.discountedPrice("$59.99", percentOff: 10), "$53.99")
        XCTAssertEqual(PromoVault.discountedPrice("$19.99", percentOff: 10), "$17.99")
    }

    func testGuessLockout() {
        let vault = PromoVault(store: InMemorySecretStore())
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        XCTAssertEqual(vault.redeem("A", now: now), .invalid(remaining: 2))
        XCTAssertEqual(vault.redeem("B", now: now), .invalid(remaining: 1))
        XCTAssertEqual(vault.redeem("C", now: now), .invalid(remaining: 0))
        XCTAssertEqual(vault.redeem("RETRACT10", now: now), .locked)
        XCTAssertEqual(vault.remainingGuesses(now: now), 0)
    }

    func testPercentOffPersists() {
        let store = InMemorySecretStore()
        let vault = PromoVault(store: store)
        XCTAssertEqual(vault.redeem("ref10"), .applied(.percentOff(10)))
        XCTAssertEqual(PromoVault(store: store).percentOff, 10)
        XCTAssertFalse(PromoVault(store: store).isComplimentaryUsername("anyone"))
        XCTAssertEqual(PromoVault(store: store).appliedCode, "REF10")
    }

    func testAllowlistGrantsComplimentaryByUsername() {
        let store = InMemorySecretStore()
        let book = PromoCampaignBook(store: store)
        XCTAssertTrue(book.replaceCampaign(codes: ["RETRACT10"], percentOff: 10, complimentaryUsernames: ["you"]))
        let vault = PromoVault(store: store, book: book)
        XCTAssertTrue(vault.isComplimentaryUsername("You"))
        XCTAssertFalse(vault.isComplimentaryUsername("someoneelse"))
        vault.clearLocalUnlocks()
        XCTAssertTrue(PromoVault(store: store, book: book).isComplimentaryUsername("you"), "allowlist is not sticky vault state")
    }
}
