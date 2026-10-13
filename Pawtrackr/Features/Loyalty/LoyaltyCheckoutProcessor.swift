//
//  LoyaltyCheckoutProcessor.swift
//  Pawtrackr
//
//  Single implementation of "award loyalty points for a checkout", shared by
//  both earn paths (CheckoutTransactionActor and LoyaltyService.applyPoints)
//  so tier multipliers, rebook bonuses, and ledger entries can never diverge.
//
//  Synchronous by design: callers are ModelActors and pass their own
//  context-bound models; this never hops isolation and never saves — the
//  caller owns the transaction boundary.
//

import Foundation
import SwiftData

enum LoyaltyCheckoutProcessor {

    /// Awards 20 points once when a completed visit is settled. Preserves historical
    /// awards and balances when an existing checkout is processed again, and writes
    /// one earned ledger entry within the caller's atomic transaction.
    ///
    /// Returns the client UUID when the client balance changed (the caller
    /// commits the local transaction), or nil when nothing changed.
    @discardableResult
    static func applyEarnings(
        visit: Visit,
        pet: Pet,
        total: Decimal,
        in context: ModelContext,
        now: Date = .now,
        config: LoyaltyConfigSnapshot = .default
    ) throws -> UUID? {
        guard let endedAt = visit.endedAt, endedAt >= visit.startedAt,
              let payment = visit.payment, payment.amount >= total.roundedMoney(),
              let client = pet.owner else { return nil }

        // Previously earned visits retain their original award and saved balance.
        guard visit.loyaltyPointsChange == 0 else { return nil }

        let tier = LoyaltyEngine.tier(
            forLifetimeEarned: LoyaltyEngine.lifetimeEarnedPoints(for: client, excluding: visit.uuid)
        )
        let isRebook = LoyaltyEngine.isRebook(
            previousVisitEndedAt: LoyaltyEngine.previousCompletedVisitDate(for: client, excluding: visit.uuid),
            checkoutAt: now
        )
        // Both checkout paths use the same deterministic earning rule.
        let points = LoyaltyEngine.preview(ticket: total, config: config, tier: tier, rebook: isRebook).total

        let previousPoints = visit.loyaltyPointsChange
        guard points != previousPoints else { return nil }

        visit.loyaltyPointsChange = points
        visit.updatedAt = .now
        visit.lastModifiedAt = .now
        visit.lastModifiedBy = DeviceIdentity.currentID

        client.loyaltyPoints += points - previousPoints
        client.updatedAt = .now
        client.lastModifiedBy = DeviceIdentity.currentID

        try upsertEarnedEntry(
            visit: visit,
            client: client,
            pet: pet,
            points: points,
            in: context
        )
        return client.uuid
    }

    /// One `.earned` ledger row per visit: a re-processed checkout (edited
    /// total) updates the existing entry instead of appending a duplicate.
    private static func upsertEarnedEntry(
        visit: Visit,
        client: Client,
        pet: Pet,
        points: Int,
        in context: ModelContext
    ) throws {
        let visitUUID = visit.uuid
        let earnedRaw = LoyaltyLedgerEntry.Kind.earned.rawValue
        var descriptor = FetchDescriptor<LoyaltyLedgerEntry>(
            predicate: #Predicate<LoyaltyLedgerEntry> {
                $0.visitUUID == visitUUID && $0.kindRaw == earnedRaw
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.points = points
            existing.balanceAfter = client.loyaltyPoints
            existing.markModified()
        } else {
            let entry = LoyaltyLedgerEntry(
                kind: .earned,
                points: points,
                clientUUID: client.uuid,
                visitUUID: visitUUID,
                balanceAfter: client.loyaltyPoints,
                reason: pet.name
            )
            context.insert(entry)
        }
    }
}
