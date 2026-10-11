import Foundation
import SwiftData

/// Value-only account data for checkout; choosing a reward never changes the balance.
struct CheckoutLoyaltyOptions: Sendable {
    let points: Int
    let tier: LoyaltyTier
    let rewards: [LoyaltyReward]
}

/// Runs inside the checkout actor's context so redemption, payment and earnings commit together.
enum LoyaltyRedemptionProcessor {
    /// Resolves the current catalog and rejects stale prices or insufficient saved points.
    static func validatedReward(_ selected: LoyaltyReward, client: Client, in context: ModelContext) throws -> LoyaltyReward {
        let templates = try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        let catalog = LoyaltyRewardCatalog.rewards(templates: templates, config: LoyaltyConfigResolver.snapshot(in: context))
        guard let current = catalog.first(where: { $0.id == selected.id }),
              current.pointCost > 0, current.pointCost == selected.pointCost,
              current.style == selected.style,
              current.checkoutCreditAmount == selected.checkoutCreditAmount else {
            throw AppError.database(AppLocalization.localized("loyalty.error.reward_unavailable", value: "This reward is no longer available. Please reopen rewards."))
        }
        guard client.loyaltyPoints >= current.pointCost else {
            throw AppError.database(AppLocalization.localized("loyalty.error.insufficient", value: "Insufficient loyalty points"))
        }
        return current
    }

    /// Deducts only previously saved points and attaches the client's choice to this visit.
    static func apply(_ reward: LoyaltyReward, client: Client, visit: Visit, credit: Decimal, in context: ModelContext, now: Date) {
        client.loyaltyPoints -= reward.pointCost
        client.updatedAt = now
        client.lastModifiedBy = DeviceIdentity.currentID
        visit.loyaltyRedeemedPoints = reward.pointCost
        visit.loyaltyRewardTitle = reward.title
        visit.loyaltyCreditApplied = credit
        context.insert(LoyaltyLedgerEntry(kind: .redeemed, points: -reward.pointCost,
                                         clientUUID: client.uuid, visitUUID: visit.uuid,
                                         balanceAfter: client.loyaltyPoints, reason: reward.title, createdAt: now))
    }
}
