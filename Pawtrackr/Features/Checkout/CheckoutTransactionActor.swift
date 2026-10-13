//
//  CheckoutTransactionActor.swift
//  Pawtrackr
//
//  Elite background actor for atomic checkout operations.
//  Ensures idempotency and thread-safety while offloading the MainActor.
//

import Foundation
import SwiftData
import OSLog

private let checkoutLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "CheckoutTransactionActor")

struct CheckoutRequest: Sendable {
    let visitUUID: UUID
    let petUUID: UUID
    let clientUUID: UUID?
    
    let amount: Decimal
    let paymentMethod: Payment.Method
    let externalReference: String?
    
    let sessionNotes: String?
    let behaviorTags: [String]
    
    let beforePhotoData: Data?
    let afterPhotoData: Data?
    
    let selectedServiceIDs: [PersistentIdentifier]
    let selectedAddOnIDs: [PersistentIdentifier]
    var selectedLoyaltyReward: LoyaltyReward? = nil
    var expectedPaymentAmount: Decimal? = nil
}

struct CheckoutResult: Sendable {
    let visitID: PersistentIdentifier
    let petID: PersistentIdentifier?
    let clientID: PersistentIdentifier?
    let endedAt: Date
    let total: Decimal
    let earnedPoints: Int
    let savedLoyaltyBalance: Int?
}

@ModelActor
final actor CheckoutTransactionActor {
    
    func process(_ request: CheckoutRequest) async throws -> CheckoutResult {
        let balanceKey = try request.clientUUID ?? fetchPet(uuid: request.petUUID).owner?.uuid ?? request.petUUID
        await LoyaltyMutationGate.shared.acquire(balanceKey)
        do {
            // A new actor context cannot carry cached balances from an earlier checkout.
            let writer = CheckoutTransactionActor(modelContainer: modelContainer)
            let result = try await writer.processReserved(request)
            await LoyaltyMutationGate.shared.release(balanceKey)
            return result
        } catch {
            await LoyaltyMutationGate.shared.release(balanceKey)
            throw error
        }
    }

    /// Owns one atomic checkout while the client balance is reserved.
    private func processReserved(_ request: CheckoutRequest) async throws -> CheckoutResult {
        let context = modelContext
        guard !request.amount.isNaN, request.amount >= .zero else {
            throw AppError.validation(.custom(message: AppLocalization.localized("checkout.error.invalid_amount", value: "Enter a valid amount.")))
        }

        // 1. Idempotency Check
        let idempotencyKey = "checkout:\(request.visitUUID.uuidString)"
        let transaction = try fetchOrCreateTransaction(idempotencyKey: idempotencyKey, request: request)
        
        if transaction.status == .succeeded, let completedAt = transaction.completedAt {
            return try buildResult(for: request.visitUUID, endedAt: completedAt)
        }
        
        transaction.markProcessing(
            amount: request.amount,
            method: request.paymentMethod,
            externalReference: request.externalReference,
            clientUUID: request.clientUUID
        )
        
        do {
            // 2. Fetch or Insert Visit
            let visit = try fetchOrCreateVisit(uuid: request.visitUUID, petUUID: request.petUUID)
            let pet = try fetchPet(uuid: request.petUUID)
            visit.ensureSessionToken()
            guard visit.pet?.uuid == pet.uuid,
                  request.clientUUID == nil || request.clientUUID == pet.owner?.uuid else {
                throw AppError.database(AppLocalization.localized("checkout.error.pet_missing", value: "Pet not found for checkout."))
            }
            
            // 3. Process Images (Parallelized background work)
            let (pBefore, pBeforeThumb, pAfter, pAfterThumb) = await processImages(
                before: request.beforePhotoData,
                after: request.afterPhotoData
            )
            
            let reward: LoyaltyReward?
            if let selected = request.selectedLoyaltyReward, let client = pet.owner {
                reward = try LoyaltyRedemptionProcessor.validatedReward(selected, client: client, in: context)
            } else if request.selectedLoyaltyReward != nil {
                throw AppError.database(AppLocalization.localized("loyalty.error.insufficient", value: "Insufficient loyalty points"))
            } else { reward = nil }
            if let reward, !reward.isApplicable(to: request.amount) {
                throw AppError.validation(.custom(message: AppLocalization.localized(
                    "checkout.loyalty.credit_exceeds_total",
                    value: "This visit total is below the reward's full credit. Choose another reward or keep the points."
                )))
            }
            let includesSpa = request.selectedServiceIDs.contains { id in
                guard let service = context.model(for: id) as? Service else { return false }
                return DefaultServiceCatalog.isSpaPackage(service.name)
            }
            if reward?.isSpaPackageReward == true && !includesSpa {
                throw AppError.validation(.custom(message: AppLocalization.localized("checkout.loyalty.spa_required", value: "Select Spa Package before redeeming the VIP Spa reward.")))
            }
            let credit = reward?.checkoutDiscount(on: request.amount, includesSpa: includesSpa) ?? .zero
            let finalTotal = max(.zero, request.amount.roundedMoney() - credit).roundedMoney()
            if let expected = request.expectedPaymentAmount, expected.roundedMoney() != finalTotal {
                throw AppError.database(AppLocalization.localized("checkout.loyalty.total_changed", value: "The reward or total changed. Review checkout again before paying."))
            }
            transaction.amount = finalTotal

            // 4. Sync State
            visit.note = request.sessionNotes
            visit.behaviorTags = request.behaviorTags
            
            visit.applyPhotos(
                before: pBefore, beforeThumb: pBeforeThumb,
                after: pAfter, afterThumb: pAfterThumb
            )
            
            // 5. Sync Line Items
            try syncVisitItems(visit: visit, serviceIDs: request.selectedServiceIDs + request.selectedAddOnIDs)
            reconcileLineItemPrices(visit: visit, finalTotal: finalTotal)
            
            // 6. Payment
            let endedAt = Date.now
            if let reward, let client = pet.owner {
                LoyaltyRedemptionProcessor.apply(reward, client: client, visit: visit, credit: credit, in: context, now: endedAt)
            }
            applyPayment(visit: visit, request: request, amount: finalTotal, endedAt: endedAt)
            
            // 7. Finalize Visit
            visit.markCheckedOut(total: finalTotal, now: endedAt)
            pet.reconcileBehaviorTagsFromCompletedVisits()
            let loyaltyConfig = LoyaltyConfigResolver.snapshot(in: modelContext)
            _ = try LoyaltyCheckoutProcessor.applyEarnings(
                visit: visit,
                pet: pet,
                total: finalTotal,
                in: modelContext,
                now: endedAt,
                config: loyaltyConfig
            )
            
            // 8. Stage summaries in the same transaction, then commit once.
            try SummaryUpdater.stageDayRebuild(for: endedAt, in: context)
            transaction.markSucceeded(completedAt: endedAt)
            try context.save()
            if let clientUUID = pet.owner?.uuid {
                NotificationCenter.default.post(name: .loyaltyBalanceDidChange, object: clientUUID)
            }
            
            return CheckoutResult(
                visitID: visit.persistentModelID,
                petID: pet.persistentModelID,
                clientID: pet.owner?.persistentModelID,
                endedAt: endedAt,
                total: finalTotal,
                earnedPoints: visit.loyaltyPointsChange,
                savedLoyaltyBalance: pet.owner?.loyaltyPoints
            )
        } catch {
            // Discard the visit, payment and points together if any part failed.
            context.rollback()
            let failedTransaction = try fetchOrCreateTransaction(idempotencyKey: idempotencyKey, request: request)
            failedTransaction.markFailed(error.localizedDescription)
            do {
                try context.save()
            } catch let saveError {
                checkoutLog.error("Checkout failed AND failed-state save also failed: original=\(error.localizedDescription) save=\(saveError.localizedDescription)")
                throw saveError
            }
            checkoutLog.error("Checkout failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Internal Logic
    
    private func fetchOrCreateTransaction(idempotencyKey: String, request: CheckoutRequest) throws -> CheckoutTransaction {
        var descriptor = FetchDescriptor<CheckoutTransaction>(
            predicate: #Predicate<CheckoutTransaction> { $0.idempotencyKey == idempotencyKey }
        )
        descriptor.fetchLimit = 1
        
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        
        let transaction = CheckoutTransaction(
            idempotencyKey: idempotencyKey,
            visitUUID: request.visitUUID,
            petUUID: request.petUUID,
            clientUUID: request.clientUUID,
            amount: request.amount,
            method: request.paymentMethod,
            externalReference: request.externalReference
        )
        modelContext.insert(transaction)
        return transaction
    }
    
    private func fetchOrCreateVisit(uuid: UUID, petUUID: UUID) throws -> Visit {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.uuid == uuid }
        )
        descriptor.fetchLimit = 1
        
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        
        let pet = try fetchPet(uuid: petUUID)
        let visit = Visit(pet: pet)
        visit.uuid = uuid
        visit.ensureSessionToken()
        modelContext.insert(visit)
        return visit
    }
    
    private func fetchPet(uuid: UUID) throws -> Pet {
        var descriptor = FetchDescriptor<Pet>(
            predicate: #Predicate<Pet> { $0.uuid == uuid }
        )
        descriptor.fetchLimit = 1
        guard let pet = try modelContext.fetch(descriptor).first else {
            throw AppError.database(AppLocalization.localized("checkout.error.pet_missing", value: "Pet not found for checkout."))
        }
        return pet
    }
    
    private func processImages(before: Data?, after: Data?) async -> (Data?, Data?, Data?, Data?) {
        await Task.detached(priority: .userInitiated) {
            let b = before.flatMap { LocalMediaPolicy.optimizedFullImageData($0, context: AppLocalization.localized("media.visit_before_photo", value: "visit before photo")) }
            let bt = before.flatMap { LocalMediaPolicy.optimizedThumbnailData($0) }
            let a = after.flatMap  { LocalMediaPolicy.optimizedFullImageData($0, context: AppLocalization.localized("media.visit_after_photo", value: "visit after photo")) }
            let at = after.flatMap  { LocalMediaPolicy.optimizedThumbnailData($0) }
            return (b, bt, a, at)
        }.value
    }
    
    private func syncVisitItems(visit: Visit, serviceIDs: [PersistentIdentifier]) throws {
        let context = modelContext
        var selected: Set<PersistentIdentifier> = []
        let serviceIDs = serviceIDs.filter { selected.insert($0).inserted }
        let currentItems = visit.items ?? []
        var nextItems: [VisitItem] = []

        // Remove items not in selection and keep selected existing items.
        for item in currentItems {
            if let serviceID = item.service?.persistentModelID, !serviceIDs.contains(serviceID) {
                visit.removeItem(item)
                context.delete(item)
            } else {
                nextItems.append(item)
            }
        }

        // Add missing items
        let existingServiceIDs = Set(currentItems.compactMap { $0.service?.persistentModelID })
        for id in serviceIDs where !existingServiceIDs.contains(id) {
            guard let service = context.model(for: id) as? Service else { continue }
            let item = VisitItem.from(service: service, visit: visit)
            context.insert(item)
            nextItems.append(item)
        }

        let order = Dictionary(uniqueKeysWithValues: serviceIDs.enumerated().map { ($0.element, $0.offset) })
        visit.items = nextItems.sorted { lhs, rhs in
            let lhsOrder = lhs.service.map { order[$0.persistentModelID] ?? Int.max } ?? Int.max
            let rhsOrder = rhs.service.map { order[$0.persistentModelID] ?? Int.max } ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    
    private func reconcileLineItemPrices(visit: Visit, finalTotal: Decimal) {
        let items = (visit.items ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        visit.items = items
        guard !items.isEmpty else { return }

        let subtotal = items.reduce(Decimal.zero) { $0 + $1.lineTotal }
        let normalizedTotal = finalTotal.roundedMoney()
        let normalizedSubtotal = subtotal.roundedMoney()
        guard normalizedSubtotal != normalizedTotal else {
            visit.recalcTotal()
            return
        }

        var allocated = Decimal.zero
        for (index, item) in items.enumerated() {
            let lineTotal: Decimal
            if index == items.count - 1 {
                lineTotal = (normalizedTotal - allocated).roundedMoney()
            } else if normalizedSubtotal > .zero {
                lineTotal = ((item.lineTotal / normalizedSubtotal) * normalizedTotal).roundedMoney()
                allocated += lineTotal
            } else {
                lineTotal = (normalizedTotal / Decimal(items.count)).roundedMoney()
                allocated += lineTotal
            }

            let quantity = Decimal(max(1, item.quantity))
            item.setUnitPrice((lineTotal / quantity).roundedMoney())
        }
        visit.recalcTotal()
    }
    
    private func applyPayment(visit: Visit, request: CheckoutRequest, amount: Decimal, endedAt: Date) {
        if let payment = visit.payment {
            payment.setAmount(amount)
            payment.method = request.paymentMethod
            payment.paidAt = endedAt
            payment.externalReference = request.externalReference
            payment.markModified()
        } else {
            let payment = Payment(
                amount: amount,
                method: request.paymentMethod,
                paidAt: endedAt,
                externalReference: request.externalReference
            )
            modelContext.insert(payment)
            visit.attachPayment(payment)
        }
    }

    private func buildResult(for visitUUID: UUID, endedAt: Date) throws -> CheckoutResult {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.uuid == visitUUID }
        )
        descriptor.fetchLimit = 1
        guard let visit = try modelContext.fetch(descriptor).first else {
            throw AppError.database(AppLocalization.localized("checkout.error.visit_missing", value: "Visit disappeared after successful checkout."))
        }
        return CheckoutResult(
            visitID: visit.persistentModelID,
            petID: visit.pet?.persistentModelID,
            clientID: visit.pet?.owner?.persistentModelID,
            endedAt: endedAt,
            total: visit.total,
            earnedPoints: visit.loyaltyPointsChange,
            savedLoyaltyBalance: visit.pet?.owner?.loyaltyPoints
        )
    }
}
