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
        let existing = try modelContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        if existing.isEmpty {
            for reward in LoyaltyRewardTemplate.seedTemplates() { modelContext.insert(reward) }
        } else {
            reconcileShippedRewards(existing)
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Updates only recognizable shipped defaults; owner-authored rewards are left intact.
    private func reconcileShippedRewards(_ existing: [LoyaltyRewardTemplate]) {
        // Match the full shipped definition. A salon may have edited a starter's
        // detail, icon, style, or cost while keeping its original title.
        let shippedDefinitions: [(String, String, Int, String, LoyaltyReward.Style, Decimal?)] = [
            ("$5 Visit Credit", "Apply a small thank-you discount at checkout.", 50, "ticket.fill", .credit, 5),
            ("$10 Visit Credit", "Reward regular clients with credit toward any groom.", 100, "banknote.fill", .credit, 10),
            ("$10 Salon Credit", "Apply toward the next completed checkout.", 100, "ticket.fill", .credit, nil),
            ("$10 Salon Credit", "Apply toward the next completed checkout.", 100, "ticket.fill", .credit, 10),
            ("15% Off Add-On", "Discount a nail grind, blueberry facial, or similar add-on.", 150, "percent", .upgrade, nil),
            ("$20 Groom Credit", "A higher-value credit for loyal repeat clients.", 200, "creditcard.fill", .credit, 20),
            ("Free Basic Groom Credit", "A premium reward that covers a future basic groom credit.", 500, "crown.fill", .vip, nil),
            ("Deep-Conditioning Treatment", "A premium coat-care add-on for a returning client.", 200, "drop.fill", .care, nil),
            ("Deshedding Upgrade", "A complimentary seasonal shed-control upgrade.", 350, "scissors", .upgrade, nil),
            ("VIP Spa Package", "Bundle a high-value add-on into the client's next visit.", 500, "sparkles", .vip, nil),
            ("$10 Salon Credit", "Reward regular clients with credit toward any groom.", 100, "banknote.fill", .credit, 10),
            ("$20 Salon Credit", "A higher-value credit for loyal repeat clients.", 200, "creditcard.fill", .credit, 20),
            ("VIP Spa Package", "A special package provided by your salon and saved with the visit.", 500, "sparkles", .vip, nil)
        ]
        let recognized = existing.filter { template in
            shippedDefinitions.contains { title, detail, cost, image, style, credit in
                template.title == title && template.detail == detail && template.pointCost == cost
                    && template.systemImage == image && template.style == style && template.creditAmount == credit
            }
        }
        guard !recognized.isEmpty else { return }

        var retainedStarterTitles = Set<String>()
        var removedIDs = Set<UUID>()
        for reward in recognized {
            switch reward.title {
            case "$5 Visit Credit", "15% Off Add-On", "Deep-Conditioning Treatment", "Deshedding Upgrade":
                modelContext.delete(reward)
                removedIDs.insert(reward.uuid)
            case "$10 Visit Credit", "$10 Salon Credit":
                retainOrRemove(reward, as: LoyaltyReward.builtInCatalog[0], seen: &retainedStarterTitles, removedIDs: &removedIDs)
            case "$20 Groom Credit", "$20 Salon Credit":
                retainOrRemove(reward, as: LoyaltyReward.builtInCatalog[1], seen: &retainedStarterTitles, removedIDs: &removedIDs)
            case "Free Basic Groom Credit", "VIP Spa Package":
                retainOrRemove(reward, as: LoyaltyReward.builtInCatalog[2], seen: &retainedStarterTitles, removedIDs: &removedIDs)
            default: break
            }
        }

        let surviving = existing.filter { !removedIDs.contains($0.uuid) }
        for (index, starter) in LoyaltyReward.builtInCatalog.enumerated() where !surviving.contains(where: { $0.title == starter.title && $0.pointCost == starter.pointCost }) {
            modelContext.insert(LoyaltyRewardTemplate(reward: starter, sortOrder: index))
        }
    }

    /// Keeps the first shipped milestone and removes duplicate shipped definitions.
    private func retainOrRemove(_ template: LoyaltyRewardTemplate, as starter: LoyaltyReward, seen: inout Set<String>, removedIDs: inout Set<UUID>) {
        guard seen.insert(starter.title).inserted else {
            modelContext.delete(template)
            removedIDs.insert(template.uuid)
            return
        }
        updateShippedReward(template, to: starter)
    }

    /// Applies a new starter definition without changing the template's identity or enabled choice.
    private func updateShippedReward(_ template: LoyaltyRewardTemplate, to starter: LoyaltyReward) {
        guard template.title != starter.title || template.detail != starter.detail || template.systemImage != starter.systemImage || template.style != starter.style || template.creditAmount != starter.checkoutCreditAmount else { return }
        template.title = starter.title
        template.detail = starter.detail
        template.systemImage = starter.systemImage
        template.styleRaw = starter.style.rawValue
        template.creditAmount = starter.checkoutCreditAmount
        template.markModified()
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
