import Foundation
import SwiftData

@ModelActor
actor LoyaltyService {

    /// Applies checkout-earned loyalty points to the visit's owning client.
    /// Delegates to LoyaltyCheckoutProcessor so this path and
    /// CheckoutTransactionActor award identical points (tier multiplier +
    /// rebook bonus) and stay idempotent on re-processing.
    func applyPoints(for visit: Visit) async throws {
        let visitUUID = visit.uuid
        let descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.uuid == visitUUID })
        let key = try modelContext.fetch(descriptor).first?.pet?.owner?.uuid ?? visitUUID
        await LoyaltyMutationGate.shared.acquire(key)
        do {
            let writer = LoyaltyService(modelContainer: modelContainer)
            try await writer.applyReservedPoints(visitUUID: visitUUID)
            await LoyaltyMutationGate.shared.release(key)
        } catch {
            await LoyaltyMutationGate.shared.release(key)
            throw error
        }
    }

    /// Uses a fresh actor context so an older cached UI visit cannot overwrite a balance.
    private func applyReservedPoints(visitUUID: UUID) throws {
        let descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.uuid == visitUUID })
        guard let localVisit = try modelContext.fetch(descriptor).first,
              let pet = localVisit.pet else { return }

        do {
            let config = LoyaltyConfigResolver.snapshot(in: modelContext)
            let clientUUID = try LoyaltyCheckoutProcessor.applyEarnings(
                visit: localVisit,
                pet: pet,
                total: localVisit.total,
                in: modelContext,
                now: localVisit.endedAt ?? .now,
                config: config
            )
            guard let clientUUID else { return }
            try modelContext.save()
            NotificationCenter.default.post(name: .loyaltyBalanceDidChange, object: clientUUID)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Loads fresh saved points and available choices without redeeming anything.
    func checkoutOptions(clientUUID: UUID) throws -> CheckoutLoyaltyOptions {
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == clientUUID })
        guard let client = try modelContext.fetch(descriptor).first else {
            throw AppError.database(AppLocalization.localized("loyalty.error.insufficient", value: "Insufficient loyalty points"))
        }
        let templates = try modelContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        let rewards = LoyaltyRewardCatalog.rewards(templates: templates, config: LoyaltyConfigResolver.snapshot(in: modelContext))
        return CheckoutLoyaltyOptions(points: client.loyaltyPoints,
                                      tier: LoyaltyEngine.tier(forLifetimeEarned: LoyaltyEngine.lifetimeEarnedPoints(for: client)),
                                      rewards: rewards)
    }

    /// Seeds defaults inside the actor without changing an existing salon's rules.
    func ensureDefaults() throws {
        _ = try fetchOrCreateConfig()
        if try modelContext.fetchCount(FetchDescriptor<LoyaltyRewardTemplate>()) == 0 {
            for reward in LoyaltyRewardTemplate.seedTemplates() { modelContext.insert(reward) }
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Fetches a context-local reward before changing its availability.
    func setRewardTemplate(uuid: UUID, isEnabled: Bool) throws {
        let descriptor = FetchDescriptor<LoyaltyRewardTemplate>(predicate: #Predicate { $0.uuid == uuid })
        guard let reward = try modelContext.fetch(descriptor).first else {
            throw AppError.database(AppLocalization.localized("loyalty.error.reward_unavailable", value: "This reward is no longer available. Please reopen rewards."))
        }
        reward.setEnabled(isEnabled)
        try modelContext.save()
    }

    /// Validates current catalog data and writes the balance and redemption atomically.
    func redeemReward(clientUUID: UUID, reward: LoyaltyReward) async throws -> Int {
        await LoyaltyMutationGate.shared.acquire(clientUUID)
        do {
            let writer = LoyaltyService(modelContainer: modelContainer)
            let balance = try await writer.redeemReservedReward(clientUUID: clientUUID, reward: reward)
            await LoyaltyMutationGate.shared.release(clientUUID)
            return balance
        } catch {
            await LoyaltyMutationGate.shared.release(clientUUID)
            throw error
        }
    }

    /// Writes a redemption in the reserved client’s fresh context.
    private func redeemReservedReward(clientUUID: UUID, reward: LoyaltyReward) throws -> Int {
        let config = try fetchOrCreateConfig()
        let templates = try modelContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        let catalog = LoyaltyRewardCatalog.rewards(templates: templates, config: config.snapshot)
        guard let current = catalog.first(where: { $0.id == reward.id }),
              current.pointCost == reward.pointCost, current.pointCost > 0 else {
            throw AppError.database(AppLocalization.localized("loyalty.error.reward_unavailable", value: "This reward is no longer available. Please reopen rewards."))
        }
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == clientUUID })
        guard let client = try modelContext.fetch(descriptor).first, client.loyaltyPoints >= current.pointCost else {
            throw AppError.database(AppLocalization.localized("loyalty.error.insufficient", value: "Insufficient loyalty points"))
        }
        do {
            client.loyaltyPoints -= current.pointCost
            stampClientMutation(client)
            recordLedgerEntry(kind: .redeemed, points: -current.pointCost, client: client, reason: current.title)
            try modelContext.save()
            NotificationCenter.default.post(name: .loyaltyBalanceDidChange, object: client.uuid)
            return client.loyaltyPoints
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Redeems points from a client balance without allowing overdrafts.
    func redeemPoints(client: Client, points: Int, reason: String? = nil) async throws {
        guard points > 0 else {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.redeem_zero", value: "Loyalty redemption must be greater than zero.")))
        }

        guard client.loyaltyPoints >= points else {
            throw AppError.database(AppLocalization.localized("loyalty.error.insufficient", value: "Insufficient loyalty points"))
        }

        client.loyaltyPoints -= points
        stampClientMutation(client)
        recordLedgerEntry(kind: .redeemed, points: -points, client: client, reason: reason)
        try modelContext.save()
    }

    /// Applies a staff-entered loyalty balance correction.
    func adjustPoints(client: Client, delta: Int, reason: String? = nil) async throws {
        guard delta != 0 else {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.adjust_zero", value: "Loyalty adjustment must not be zero.")))
        }

        let adjustedBalance = client.loyaltyPoints + delta
        guard adjustedBalance >= 0 else {
            throw AppError.database(AppLocalization.localized("loyalty.error.overdraw", value: "Loyalty adjustment cannot overdraw the client balance"))
        }

        client.loyaltyPoints = adjustedBalance
        stampClientMutation(client)
        recordLedgerEntry(kind: .adjusted, points: delta, client: client, reason: reason)
        try modelContext.save()
    }

    func updateConfig(
        earnMode: LoyaltyEarnMode? = nil,
        pointsPerDollar: Decimal? = nil,
        pointsPerVisit: Int? = nil,
        redemptionThreshold: Int? = nil,
        isRewardsCatalogEnabled: Bool? = nil
    ) throws {
        if let pointsPerDollar, pointsPerDollar < .zero {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.points_per_dollar_negative", value: "Points per dollar cannot be negative.")))
        }
        if let pointsPerVisit, pointsPerVisit < 0 {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.points_per_visit_negative", value: "Points per visit cannot be negative.")))
        }
        if let redemptionThreshold, redemptionThreshold <= 0 {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.threshold_zero", value: "Reward threshold must be greater than zero.")))
        }

        let config = try fetchOrCreateConfig()
        if let earnMode {
            config.setEarnMode(earnMode)
        }
        if let pointsPerDollar {
            config.setPointsPerDollar(pointsPerDollar)
        }
        if let pointsPerVisit {
            config.setPointsPerVisit(pointsPerVisit)
        }
        if let redemptionThreshold {
            config.setRedemptionThreshold(redemptionThreshold)
        }
        if let isRewardsCatalogEnabled {
            config.setRewardsCatalogEnabled(isRewardsCatalogEnabled)
        }
        try modelContext.save()
    }

    func createRewardTemplate(
        title: String,
        detail: String,
        pointCost: Int,
        systemImage: String,
        style: LoyaltyReward.Style,
        creditAmount: Decimal? = nil
    ) throws {
        guard pointCost > 0 else {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.cost_zero", value: "Reward cost must be greater than zero.")))
        }

        if let creditAmount, creditAmount.roundedMoney() <= .zero {
            throw AppError.validation(.custom(message: AppLocalization.localized("loyalty.error.credit_zero", value: "Credit amount must be greater than zero.")))
        }
        let templates = try modelContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        let nextOrder = (templates.map(\.sortOrder).max() ?? -1) + 1
        let reward = LoyaltyRewardTemplate(
            title: title,
            detail: detail,
            pointCost: pointCost,
            systemImage: systemImage,
            styleRaw: style.rawValue,
            sortOrder: nextOrder,
            creditAmount: creditAmount?.roundedMoney()
        )
        modelContext.insert(reward)
        try modelContext.save()
    }

    func setRewardTemplate(_ reward: LoyaltyRewardTemplate, isEnabled: Bool) throws {
        reward.setEnabled(isEnabled)
        try modelContext.save()
    }

    func resetRewardTemplatesToDiscountLadder() throws {
        let existing = try modelContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        for reward in existing {
            modelContext.delete(reward)
        }
        for template in LoyaltyRewardTemplate.seedTemplates() {
            modelContext.insert(template)
        }
        try modelContext.save()
    }

    private func recordLedgerEntry(kind: LoyaltyLedgerEntry.Kind, points: Int, client: Client, reason: String?) {
        let entry = LoyaltyLedgerEntry(
            kind: kind,
            points: points,
            clientUUID: client.uuid,
            balanceAfter: client.loyaltyPoints,
            reason: reason
        )
        modelContext.insert(entry)
    }

    private func stampClientMutation(_ client: Client) {
        client.updatedAt = .now
        client.lastModifiedBy = DeviceIdentity.currentID
    }

    private func fetchOrCreateConfig() throws -> LoyaltyConfig {
        var descriptor = FetchDescriptor<LoyaltyConfig>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }

        let config = LoyaltyConfig()
        modelContext.insert(config)
        return config
    }
}
