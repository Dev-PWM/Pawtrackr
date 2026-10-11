import Foundation

/// A built-in, schema-free reward catalog entry for the premium loyalty UI.
struct LoyaltyReward: Identifiable, Hashable, Codable, Sendable {
    enum Style: String, Hashable, Codable, Sendable {
        case credit
        case care
        case upgrade
        case vip
    }

    let id: String
    let title: String
    let detail: String
    let pointCost: Int
    let systemImage: String
    let style: Style
    /// Explicit currency value for a credit. Nil for salon-provided benefits.
    var creditAmount: Decimal? = nil

    /// Recognizes shipped credit definitions while preserving existing stored templates.
    var checkoutCreditAmount: Decimal? {
        guard style == .credit else { return nil }
        if let creditAmount, creditAmount > 0 { return creditAmount.roundedMoney() }
        switch (title, pointCost) {
        case ("$5 Visit Credit", 50): return 5
        case ("$10 Visit Credit", 100), ("$10 Salon Credit", 100): return 10
        case ("$20 Groom Credit", 200): return 20
        default: return nil
        }
    }

    /// Credits cannot make a payment negative; all currency arithmetic stays Decimal.
    func creditDiscount(on subtotal: Decimal) -> Decimal {
        min(max(.zero, subtotal), checkoutCreditAmount ?? .zero).roundedMoney()
    }

    @MainActor
    var fulfillmentDescription: String {
        if let credit = checkoutCreditAmount {
            return String(format: AppLocalization.localized("loyalty.reward.credit_fmt", value: "%@ automatically deducted at checkout"), credit.moneyString)
        }
        return AppLocalization.localized("loyalty.reward.salon_provided", value: "Provided by your salon; recorded in visit history")
    }

    /// The starter catalog used until configurable rewards land in the V2 loyalty schema.
    static let builtInCatalog: [LoyaltyReward] = [
        LoyaltyReward(
            id: "visit-credit-5",
            title: "$5 Visit Credit",
            detail: "Apply a small thank-you discount at checkout.",
            pointCost: 50,
            systemImage: "ticket.fill",
            style: .credit
        ),
        LoyaltyReward(
            id: "visit-credit-10",
            title: "$10 Visit Credit",
            detail: "Reward regular clients with credit toward any groom.",
            pointCost: 100,
            systemImage: "banknote.fill",
            style: .credit
        ),
        LoyaltyReward(
            id: "addon-discount-15",
            title: "15% Off Add-On",
            detail: "Discount a nail grind, blueberry facial, or similar add-on.",
            pointCost: 150,
            systemImage: "percent",
            style: .upgrade
        ),
        LoyaltyReward(
            id: "groom-credit-20",
            title: "$20 Groom Credit",
            detail: "A higher-value credit for loyal repeat clients.",
            pointCost: 200,
            systemImage: "creditcard.fill",
            style: .credit
        ),
        LoyaltyReward(
            id: "basic-groom-credit",
            title: "Free Basic Groom Credit",
            detail: "A premium reward that covers a future basic groom credit.",
            pointCost: 500,
            systemImage: "crown.fill",
            style: .vip
        )
    ]

    /// Returns true when the supplied balance can cover this reward.
    func isRedeemable(with balance: Int) -> Bool {
        balance >= pointCost
    }
}
