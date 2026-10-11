//
//  DataStoreService.swift
//  Pawtrackr
//
//  Centralized service for data access. Acts as the Single Source of Truth
//  for all SwiftData operations, providing a reactive interface to the UI.
//

import Foundation
import SwiftData
import Observation
import OSLog

@Observable
@MainActor
public final class DataStoreService {
    let container: ModelContainer
    private let mainContext: ModelContext

    init(container: ModelContainer) {
        self.container = container
        self.mainContext = container.mainContext
    }

    convenience init(inMemory: Bool) {
        do {
            let schema = Schema(PawtrackrSchema.models)
            // For tests and QualityControl only. Production uses the shared
            // bootstrap container after its backup and restore work finishes.
            let config = LocalStoreConfiguration.make(schema: schema, isStoredInMemoryOnly: inMemory)
            let container = try ModelContainer(for: schema, configurations: [config])
            self.init(container: container)
        } catch {
            Logger.dataStore.critical("Failed to create DataStoreService container: \(error.localizedDescription, privacy: .public)")
            preconditionFailure("DataStoreService could not initialize its ModelContainer: \(error.localizedDescription)")
        }
    }
    /// Fetches a list of persistent models with a given predicate and optional sort descriptors.
    @MainActor
    func fetch<T: PersistentModel>(_ predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) throws -> [T] {
        let descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
        // Optimization: Prefetch relationships if needed
        return try mainContext.fetch(descriptor)
    }

    /// Performs an asynchronous fetch in a detached context to keep the UI responsive.
    nonisolated func fetchAsync<T: PersistentModel>(_ predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = []) async throws -> [T] {
        let container = self.container
        return try await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            let descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
            return try bgContext.fetch(descriptor)
        }.value
    }

    /// Reads fresh account presentation values without passing model instances across actors.
    nonisolated func fetchLoyaltyAccount(clientUUID: UUID) async throws -> CheckoutLoyaltyOptions? {
        let container = self.container
        return try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == clientUUID })
            descriptor.fetchLimit = 1
            guard let client = try context.fetch(descriptor).first else { return nil }
            return CheckoutLoyaltyOptions(points: client.loyaltyPoints,
                tier: LoyaltyEngine.tier(forLifetimeEarned: LoyaltyEngine.lifetimeEarnedPoints(for: client)), rewards: [])
        }.value
    }

    /// Reads the committed balance in a fresh context and returns only a value.
    /// Actor saves can leave an already-materialized UI Client's attributes stale.
    nonisolated func fetchLoyaltyBalance(clientUUID: UUID) async throws -> Int? {
        let container = self.container
        return try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == clientUUID })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.loyaltyPoints
        }.value
    }

    /// Yields a tick whenever the main context records changes.
    ///
    /// FRAGILE: SwiftData wraps Core Data, so the Core Data
    /// `NSManagedObjectContextObjectsDidChange` notification *currently* fires
    /// when a SwiftData ModelContext mutates. This is undocumented — Apple
    /// could rev SwiftData's internals at any release and silently break this
    /// stream. If the UI stops reacting to writes after a future iOS update,
    /// this observer is the first thing to suspect; replace with a SwiftData-
    /// native subscription if/when one ships.
    func observeChanges<T: PersistentModel>(_ modelType: T.Type) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange,
                object: mainContext,
                queue: .main
            ) { _ in
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// Resolves checkout navigation against a fresh context so a completed visit
    /// cannot be reopened from stale UI relationships after actor-owned checkout.
    @MainActor
    func resolveActiveCheckoutVisitID(
        for petID: PersistentIdentifier,
        preferredVisitID: PersistentIdentifier?,
        allowsCompletedPreferredVisit: Bool = false
    ) throws -> PersistentIdentifier? {
        let freshContext = ModelContext(container)

        guard let pet = freshContext.model(for: petID) as? Pet else {
            return nil
        }

        if let preferredVisitID,
           let visit = freshContext.model(for: preferredVisitID) as? Visit,
           visit.pet?.persistentModelID == petID {
            if visit.endedAt == nil || allowsCompletedPreferredVisit {
                return preferredVisitID
            }
        }

        let petUUID = pet.uuid
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { visit in
                visit.endedAt == nil && visit.pet?.uuid == petUUID
            },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        descriptor.relationshipKeyPathsForPrefetching = [\Visit.pet]
        return try freshContext.fetch(descriptor).first?.persistentModelID
    }
}

private extension Logger {
    static let dataStore = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "DataStoreService")
}
