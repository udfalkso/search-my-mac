import Foundation

enum StoreAccessState: Equatable {
    case notStarted
    case trial(expiresAt: Date)
    case expired
    case unlocked

    var allowsSearch: Bool {
        switch self {
        case .trial, .unlocked: true
        case .notStarted, .expired: false
        }
    }
}

enum StoreAccessPolicy {
    static let trialProductID = "com.searchmymac.app.trial7day"
    static let unlockProductID = "com.searchmymac.app.fullunlock"
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    struct Purchase {
        let productID: String
        let originalPurchaseDate: Date
        let isRevoked: Bool
    }

    /// Call only with StoreKit-verified transactions. A restored trial uses its
    /// original purchase date rather than starting a new week on each Mac.
    static func evaluate(_ purchases: [Purchase], now: Date) -> StoreAccessState {
        let valid = purchases.filter { !$0.isRevoked }
        if valid.contains(where: { $0.productID == unlockProductID }) { return .unlocked }
        guard let start = valid.filter({ $0.productID == trialProductID })
            .map(\.originalPurchaseDate).min() else { return .notStarted }
        let expiry = start.addingTimeInterval(trialDuration)
        guard now >= start, now < expiry else { return .expired }
        return .trial(expiresAt: expiry)
    }
}
