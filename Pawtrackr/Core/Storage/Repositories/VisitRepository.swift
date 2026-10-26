//
//  VisitRepository.swift
//  Pawtrackr
//
//  Manages Visit lifecycle and operations.
//

import Foundation
import SwiftData
import OSLog

@MainActor
protocol VisitRepositoryProtocol: Sendable {
    func fetchVisits(predicate: Predicate<Visit>?, sortBy: [SortDescriptor<Visit>], limit: Int?) async throws -> [Visit]
    func saveVisit(_ visit: Visit) async throws
    func deleteVisit(_ visit: Visit) async throws
    func checkIn(pet: Pet, date: Date) async throws -> Visit
    func checkOut(visit: Visit, total: Decimal?, now: Date) async throws
}

@MainActor
final class VisitRepository: VisitRepositoryProtocol {
    private let modelContext: ModelContext
    private let eventBus: GlobalEventBus
    private let loyaltyService: LoyaltyService
    
    /// `eventBus` is required: a default would create a fresh bus with no
    /// subscribers and silently swallow every `.refreshRequired` / checkout
    /// completion event. Pass the same bus the rest of the app holds.
    init(modelContext: ModelContext, eventBus: GlobalEventBus) {
        self.modelContext = modelContext
        self.eventBus = eventBus
        self.loyaltyService = LoyaltyService(modelContainer: modelContext.container)
    }
    
    func fetchVisits(predicate: Predicate<Visit>?, sortBy: [SortDescriptor<Visit>], limit: Int?) async throws -> [Visit] {
        var descriptor = FetchDescriptor<Visit>(predicate: predicate, sortBy: sortBy)
        if let limit = limit {
            descriptor.fetchLimit = limit
        }
        return try modelContext.fetch(descriptor)
    }
    
    func saveVisit(_ visit: Visit) async throws {
        if visit.modelContext == nil {
            modelContext.insert(visit)
        }
        visit.ensureSessionToken()
        try modelContext.save()
    }
    
    /// Deletes a visit and takes back what it did to the owner's loyalty
    /// balance in the same save: the points it earned come off and the points
    /// spent on a reward there are refunded, recorded as one `.adjusted`
    /// ledger row. The balance never goes below zero (the earned points may
    /// already be spent). Runs under `LoyaltyMutationGate`, like checkout.
    func deleteVisit(_ visit: Visit) async throws {
        let visitUUID = visit.uuid
        let gateKey = visit.pet?.owner?.uuid ?? visitUUID
        let container = modelContext.container

        await LoyaltyMutationGate.shared.acquire(gateKey)
        let outcome: VisitDeletionOutcome
        do {
            // A fresh background context: the cached UI models may hold an
            // older balance than the store.
            outcome = try await Task.detached(priority: .userInitiated) {
                try Self.deleteReversingLoyalty(visitUUID: visitUUID, in: ModelContext(container))
            }.value
            await LoyaltyMutationGate.shared.release(gateKey)
        } catch {
            await LoyaltyMutationGate.shared.release(gateKey)
            throw error
        }

        if outcome.balanceChange != 0, let clientUUID = outcome.clientUUID {
            NotificationCenter.default.post(name: .loyaltyBalanceDidChange, object: clientUUID)
        }
        eventBus.publish(.refreshRequired)
    }

    private struct VisitDeletionOutcome: Sendable {
        let clientUUID: UUID?
        let balanceChange: Int
    }

    /// Deletes the visit and its loyalty effect in one save, then rebuilds the
    /// derived summaries. The balance never goes below zero: the earned points
    /// may already be spent.
    nonisolated private static func deleteReversingLoyalty(visitUUID: UUID, in context: ModelContext) throws -> VisitDeletionOutcome {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.uuid == visitUUID })
        descriptor.fetchLimit = 1
        guard let visit = try context.fetch(descriptor).first else {
            return VisitDeletionOutcome(clientUUID: nil, balanceChange: 0)
        }
        let started = visit.startedAt
        let ended = visit.endedAt
        let client = visit.pet?.owner

        var change = 0
        if let client {
            let earned = max(0, visit.loyaltyPointsChange)
            let refunded = max(0, visit.loyaltyRedeemedPoints)
            let newBalance = max(0, client.loyaltyPoints - earned + refunded)
            change = newBalance - client.loyaltyPoints
            if change != 0 {
                client.loyaltyPoints = newBalance
                client.updatedAt = .now
                client.lastModifiedBy = DeviceIdentity.currentID
                context.insert(LoyaltyLedgerEntry(
                    kind: .adjusted,
                    points: change,
                    clientUUID: client.uuid,
                    visitUUID: visitUUID,
                    balanceAfter: newBalance,
                    reason: visit.pet?.name
                ))
            }
        }

        context.delete(visit)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // Derived caches: a failure is logged and the launch rebuild repairs it.
        let cal = Calendar.current
        SummaryUpdater.rebuildDay(for: started, in: context)
        if let ended, cal.startOfDay(for: ended) != cal.startOfDay(for: started) {
            SummaryUpdater.rebuildDay(for: ended, in: context)
        }
        // A day rebuild only refreshes clients who still have visits that day.
        if let client {
            do {
                try SummaryUpdater.upsertClientInsightSummary(for: client, in: context)
                if context.hasChanges { try context.save() }
            } catch {
                Logger.visits.error("VisitRepository: Client summary refresh after visit delete failed: \(error.localizedDescription)")
            }
        }
        return VisitDeletionOutcome(clientUUID: client?.uuid, balanceChange: change)
    }
    
    func checkIn(pet: Pet, date: Date) async throws -> Visit {
        guard pet.archivedAt == nil else {
            throw AppError.validation(.custom(message: AppLocalization.localized("pet.editor.removed_checkin", value: "Restore this pet before starting a new session.")))
        }
        Logger.visits.info("VisitRepository: CheckIn initiated for petID=\(pet.uuid.uuidString, privacy: .public) petName=\(pet.name, privacy: .private(mask: .hash))")
        
        // Re-fetch pet in current context to ensure relationship integrity
        let petID = pet.persistentModelID
        guard let contextPet = modelContext.model(for: petID) as? Pet else {
             Logger.visits.error("VisitRepository: Could not fetch pet in current context")
             throw AppError.database(AppLocalization.localized("visit.error.pet_missing", value: "Pet not found."))
        }
        
        if let existing = try activeVisit(for: contextPet) {
            Logger.visits.info("VisitRepository: Pet already checked in, returning existing visit")
            existing.ensureSessionToken()
            return existing
        }

        let visit = Visit(pet: contextPet, startedAt: date)
        modelContext.insert(visit)
        Logger.visits.info("VisitRepository: Visit object created and inserted into context")
        
        do {
            try modelContext.save()
            Logger.visits.info("VisitRepository: Context save successful for new visit. visitID=\(visit.uuid)")
        } catch {
            Logger.visits.error("VisitRepository: Context save FAILED: \(error.localizedDescription)")
            throw error
        }
        
        
        Logger.visits.info("VisitRepository: Attempting EventBus publish...")
        eventBus.publish(.refreshRequired)
        Logger.visits.info("VisitRepository: EventBus refresh published")
        
        Logger.visits.info("VisitRepository: Attempting visitDidStart notification...")
        NotificationCenter.default.post(name: .visitDidStart, object: visit)
        Logger.visits.info("VisitRepository: visitDidStart notification posted")
        
        return visit
    }
    
    func checkOut(visit: Visit, total: Decimal?, now: Date) async throws {
        Logger.visits.info("VisitRepository: Checking out visit \(visit.uuid)")
        visit.markCheckedOut(total: total ?? visit.effectiveTotal, now: now)
        
        // Save the visit and its payment
        try modelContext.save()
        
        // Apply loyalty points
        try await loyaltyService.applyPoints(for: visit)
        

        SummaryUpdater.rebuildDay(for: now, in: modelContext)
        let completion = CheckoutCompletionContext(
            visitID: visit.persistentModelID,
            petID: visit.pet?.persistentModelID,
            clientID: visit.pet?.owner?.persistentModelID,
            endedAt: now,
            total: visit.total
        )
        eventBus.publish(.checkoutCompleted(completion))
        var userInfo: [String: Any] = [
            VisitDidCompleteKey.visitID.rawValue: completion.visitID,
            VisitDidCompleteKey.endedAt.rawValue: completion.endedAt,
            VisitDidCompleteKey.total.rawValue: completion.total
        ]
        if let petID = completion.petID {
            userInfo[VisitDidCompleteKey.petID.rawValue] = petID
        }
        if let clientID = completion.clientID {
            userInfo[VisitDidCompleteKey.clientID.rawValue] = clientID
        }
        NotificationCenter.default.post(name: .visitDidComplete, object: visit, userInfo: userInfo)
        Logger.visits.info("VisitRepository: Checkout complete, event published")
    }

    private func activeVisit(for pet: Pet) throws -> Visit? {
        let freshContext = ModelContext(modelContext.container)
        let petUUID = pet.uuid
        let activeDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        let visits = try freshContext.fetch(activeDescriptor)
        let active = visits.first { $0.pet?.uuid == petUUID }
        if let activeID = active?.persistentModelID,
           let contextActive = modelContext.model(for: activeID) as? Visit {
            Logger.visits.info("VisitRepository: activeVisit found for petID=\(petUUID.uuidString, privacy: .public): visitID=\(contextActive.uuid.uuidString, privacy: .public), endedAt=\(String(describing: contextActive.endedAt), privacy: .public)")
            return contextActive
        } else {
            Logger.visits.info("VisitRepository: No active visit found for petID=\(petUUID.uuidString, privacy: .public)")
            return nil
        }
    }
}

private extension Logger {
    static let visits = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "VisitRepository")
}
