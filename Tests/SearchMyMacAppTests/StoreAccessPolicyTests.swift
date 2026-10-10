import Foundation
import Testing
@testable import SearchMyMacApp

struct StoreAccessPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func trialExpiresAtExactlySevenDays() {
        let trial = StoreAccessPolicy.Purchase(productID: StoreAccessPolicy.trialProductID, originalPurchaseDate: start, isRevoked: false)
        let expiry = start.addingTimeInterval(7 * 24 * 60 * 60)
        #expect(StoreAccessPolicy.evaluate([trial], now: expiry.addingTimeInterval(-1)) == .trial(expiresAt: expiry))
        #expect(StoreAccessPolicy.evaluate([trial], now: expiry) == .expired)
        #expect(StoreAccessPolicy.evaluate([trial], now: start.addingTimeInterval(-1)) == .expired)
    }

    @Test func permanentUnlockOverridesExpiredTrialButRevocationRemovesAccess() {
        let trial = StoreAccessPolicy.Purchase(productID: StoreAccessPolicy.trialProductID, originalPurchaseDate: start, isRevoked: false)
        let unlock = StoreAccessPolicy.Purchase(productID: StoreAccessPolicy.unlockProductID, originalPurchaseDate: start, isRevoked: false)
        let revoked = StoreAccessPolicy.Purchase(productID: StoreAccessPolicy.unlockProductID, originalPurchaseDate: start, isRevoked: true)
        let now = start.addingTimeInterval(30 * 24 * 60 * 60)
        #expect(StoreAccessPolicy.evaluate([trial, unlock], now: now) == .unlocked)
        #expect(StoreAccessPolicy.evaluate([trial, revoked], now: now) == .expired)
        #expect(StoreAccessPolicy.evaluate([revoked], now: now) == .notStarted)
    }

    @Test func restoringTrialDoesNotRestartItAndUnknownProductsDoNotUnlock() {
        let old = StoreAccessPolicy.Purchase(productID: StoreAccessPolicy.trialProductID, originalPurchaseDate: start, isRevoked: false)
        let newer = StoreAccessPolicy.Purchase(productID: StoreAccessPolicy.trialProductID, originalPurchaseDate: start.addingTimeInterval(8 * 24 * 60 * 60), isRevoked: false)
        let unknown = StoreAccessPolicy.Purchase(productID: "unrelated", originalPurchaseDate: start, isRevoked: false)
        #expect(StoreAccessPolicy.evaluate([old, newer], now: newer.originalPurchaseDate) == .expired)
        #expect(StoreAccessPolicy.evaluate([unknown], now: start) == .notStarted)
        #expect(StoreAccessPolicy.evaluate([], now: start) == .notStarted)
    }
}
