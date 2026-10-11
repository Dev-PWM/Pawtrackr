import Foundation
import SwiftData

/// One checkout's points, as `LoyaltyEngine.preview` works them out.
struct LoyaltyEarnPreview: Equatable, Sendable {
    /// From the earning rule alone: points per currency unit of the total,
    /// or the flat points per visit.
    let basePoints: Int
    let tier: LoyaltyTier
    /// `basePoints` after the tier's multiplier (rounded down).
    let tierPoints: Int
    /// `LoyaltyEngine.rebookBonusPoints`, or 0.
    let rebookBonus: Int

    /// What the visit awards.
    var total: Int { tierPoints + rebookBonus }
}

/// Domain engine for loyalty point calculations.
///
/// All functions are pure and integer-deterministic so the two earn paths
/// (`CheckoutTransactionActor` and `LoyaltyService.applyPoints`) always
/// compute identical results, on any device.
struct LoyaltyEngine {

    /// Flat bonus for a client who rebooks within `rebookWindowDays` of their
    /// previous completed visit.
    static let rebookBonusPoints = 20

    /// How soon a return visit must happen (in days) to earn the rebook bonus.
    static let rebookWindowDays = 45

    /// Calculates base points earned from the configured earning rule.
    static func calculatePoints(for total: Decimal, config: LoyaltyConfigSnapshot = .default) -> Int {
        guard total > .zero else { return 0 }

        switch config.earnMode {
        case .pointsPerDollar:
            let roundedTotal = total.roundedMoney()
            let rawPoints = (roundedTotal * config.pointsPerDollar).roundedMoney(scale: 4)
            return max(0, (rawPoints as NSDecimalNumber).intValue)
        case .flatPerVisit:
            return max(0, config.pointsPerVisit)
        }
    }

    /// Applies the tier's earn multiplier to base points. Integer math only:
    /// `floor(base * percent / 100)`, never negative.
    static func earnedPoints(base: Int, tier: LoyaltyTier) -> Int {
        guard base > 0 else { return 0 }
        return base * tier.earnMultiplierPercent / 100
    }

    /// The tier a client holds for the given lifetime visit-earned total.
    static func tier(forLifetimeEarned earned: Int) -> LoyaltyTier {
        LoyaltyTier.allCases.last { earned >= $0.threshold } ?? .bronze
    }

    /// Fractional progress (0...1) from the current tier's threshold toward
    /// the next tier. Returns 1 at the top tier.
    static func tierProgress(lifetimeEarned: Int) -> Double {
        let current = tier(forLifetimeEarned: lifetimeEarned)
        guard let next = current.next else { return 1 }
        let span = max(1, next.threshold - current.threshold)
        let into = lifetimeEarned - current.threshold
        return min(1, max(0, Double(into) / Double(span)))
    }

    /// Points still needed to reach the next tier, or nil at the top tier.
    static func pointsUntilNextTier(lifetimeEarned: Int) -> Int? {
        guard let next = tier(forLifetimeEarned: lifetimeEarned).next else { return nil }
        return max(0, next.threshold - lifetimeEarned)
    }

    /// Whether a checkout at `checkoutAt` counts as a rebook: the client's
    /// previous completed visit ended at most `rebookWindowDays` earlier.
    /// A "previous visit" timestamped after `checkoutAt` (device clock skew)
    /// doesn't count.
    static func isRebook(previousVisitEndedAt: Date?, checkoutAt: Date) -> Bool {
        guard let previousVisitEndedAt else { return false }
        let elapsed = checkoutAt.timeIntervalSince(previousVisitEndedAt)
        let window = TimeInterval(rebookWindowDays) * 86_400
        return elapsed >= 0 && elapsed <= window
    }

    /// Rebook bonus: awarded only when the visit actually earned base points
    /// and the client's previous completed visit falls inside the window.
    static func rebookBonus(previousVisitEndedAt: Date?, checkoutAt: Date, basePoints: Int) -> Int {
        guard isRebook(previousVisitEndedAt: previousVisitEndedAt, checkoutAt: checkoutAt) else { return 0 }
        return rebookBonus(basePoints: basePoints, isRebook: true)
    }

    private static func rebookBonus(basePoints: Int, isRebook: Bool) -> Int {
        guard basePoints > 0, isRebook else { return 0 }
        return rebookBonusPoints
    }

    /// The points one checkout earns, step by step. This is THE earn rule:
    /// `LoyaltyCheckoutProcessor.applyEarnings` awards `preview(...).total`,
    /// so the checkout and repository paths always award the same value.
    ///
    /// - Parameters:
    ///   - ticket: what the client pays at checkout: the services, or the
    ///     amount typed over them.
    ///   - tier: the client's tier before this visit.
    ///   - rebook: the client's previous completed visit ended within
    ///     `rebookWindowDays` (`isRebook`).
    static func preview(
        ticket: Decimal,
        config: LoyaltyConfigSnapshot,
        tier: LoyaltyTier,
        rebook: Bool
    ) -> LoyaltyEarnPreview {
        let base = calculatePoints(for: ticket, config: config)
        return LoyaltyEarnPreview(
            basePoints: base,
            tier: tier,
            tierPoints: earnedPoints(base: base, tier: tier),
            rebookBonus: rebookBonus(basePoints: base, isRebook: rebook)
        )
    }

    // MARK: - Client derivations

    /// Lifetime points earned through completed visits (positive changes only),
    /// optionally excluding one visit — pass the visit being (re)checked out so
    /// recomputing its award is stable against its own previous value.
    static func lifetimeEarnedPoints(for client: Client?, excluding excludedVisitUUID: UUID? = nil) -> Int {
        guard let client else { return 0 }
        var earned = 0
        for pet in client.pets ?? [] {
            for visit in pet.visits ?? [] where visit.uuid != excludedVisitUUID {
                earned += max(0, visit.loyaltyPointsChange)
            }
        }
        return earned
    }

    /// When the client's most recent completed visit ended, excluding the
    /// visit currently being checked out.
    static func previousCompletedVisitDate(for client: Client?, excluding excludedVisitUUID: UUID? = nil) -> Date? {
        guard let client else { return nil }
        var latest: Date?
        for pet in client.pets ?? [] {
            for visit in pet.visits ?? [] where visit.uuid != excludedVisitUUID {
                guard let ended = visit.endedAt else { continue }
                if latest.map({ ended > $0 }) ?? true {
                    latest = ended
                }
            }
        }
        return latest
    }
}
