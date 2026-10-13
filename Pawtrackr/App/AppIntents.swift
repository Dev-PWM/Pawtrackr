import AppIntents
import Foundation
import SwiftData
import OSLog

// MARK: - Pet Entity for Assistant Awareness
struct PetEntity: AppEntity {
    typealias ID = UUID

    let id: UUID
    let name: String
    
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pet")
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    
    static var defaultQuery = PetEntityQuery()
}

private extension PetEntity {
    init(pet: Pet) {
        self.id = pet.uuid
        self.name = pet.name
    }
}

struct PetEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PetEntity] {
        let container = try IntentContainerProvider.sharedContainer()
        // Intent invocations must read committed sessions rather than a cached UI graph.
        let context = ModelContext(container)
        var entities: [PetEntity] = []
        entities.reserveCapacity(identifiers.count)

        for identifier in identifiers {
            let descriptor = FetchDescriptor<Pet>(
                predicate: #Predicate { pet in pet.uuid == identifier && pet.archivedAt == nil },
                sortBy: [SortDescriptor(\Pet.name)]
            )
            if let pet = try context.fetch(descriptor).first {
                entities.append(PetEntity(pet: pet))
            }
        }

        return entities
    }

    @MainActor
    func entities(matching string: String) async throws -> [PetEntity] {
        let container = try IntentContainerProvider.sharedContainer()
        // Intent invocations must read committed sessions rather than a cached UI graph.
        let context = ModelContext(container)
        let normalizedQuery = string.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase

        // Push the predicate into the FetchDescriptor instead of fetching the
        // whole Pet table and filtering in memory. With many pets, the old
        // approach made every Siri lookup O(n) on disk + memory.
        var descriptor: FetchDescriptor<Pet>
        if normalizedQuery.isEmpty {
            descriptor = FetchDescriptor<Pet>(predicate: #Predicate { $0.archivedAt == nil }, sortBy: [SortDescriptor(\Pet.name)])
        } else {
            descriptor = FetchDescriptor<Pet>(
                predicate: #Predicate { pet in pet.archivedAt == nil && pet.name.localizedStandardContains(normalizedQuery) },
                sortBy: [SortDescriptor(\Pet.name)]
            )
        }
        descriptor.fetchLimit = 10

        return try context.fetch(descriptor).map(PetEntity.init(pet:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PetEntity] {
        let container = try IntentContainerProvider.sharedContainer()
        // Intent invocations must read committed sessions rather than a cached UI graph.
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Pet>(predicate: #Predicate { $0.archivedAt == nil }, sortBy: [SortDescriptor(\Pet.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 10
        return try context.fetch(descriptor).map(PetEntity.init(pet:))
    }
}

// MARK: - Check In Pet Intent
struct CheckInPetIntent: AppIntent {
    static var title: LocalizedStringResource = "Check In Pet"
    static var description = IntentDescription("Starts a new grooming session.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Pet")
    var pet: PetEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try IntentContainerProvider.sharedContainer()
        // Intent invocations must read committed sessions rather than a cached UI graph.
        let context = ModelContext(container)
        let petID = pet.id
        let descriptor = FetchDescriptor<Pet>(
            predicate: #Predicate { model in model.uuid == petID && model.archivedAt == nil },
            sortBy: [SortDescriptor(\Pet.name)]
        )

        guard let model = try context.fetch(descriptor).first else {
            throw AppError.database("Could not find \(pet.name).")
        }

        guard model.activeVisit == nil else {
            return .result(dialog: "\(model.name) is already checked in.")
        }

        // Use a fresh GlobalEventBus here: the running app's bus instance is
        // owned by PawtrackrApp and isn't reachable from this process boundary.
        // The intent's downstream consumers rely on NotificationCenter posts
        // from VisitRepository.checkIn (which use the global NotificationCenter),
        // so dashboards still refresh via that path.
        let repo = VisitRepository(modelContext: context, eventBus: GlobalEventBus())
        _ = try await repo.checkIn(pet: model, date: .now)
        return .result(dialog: "Checked in \(model.name).")
    }
}

// MARK: - Get Business Stats Intent
struct GetBusinessStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Business Stats"
    static var description = IntentDescription("Provides a quick summary of today's performance.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = try IntentContainerProvider.sharedContainer()
        let repo = DashboardRepository(modelContext: container.mainContext)
        
        let kpis = try await repo.fetchKPIs()
        
        let summary = """
        Today's Summary:
        - \(kpis.completedToday) visits completed.
        - Total revenue: \(kpis.revenueToday.moneyString).
        - \(kpis.inProgressCount) sessions still in progress.
        """
        
        return .result(value: summary)
    }
}

// MARK: - Container Provider
enum IntentContainerProvider {
    /// The container the app opened, or on a cold intent launch the one
    /// AppStoreBootstrap opens now, after the same store-file work. A second
    /// `.automatic` container here would run a second mirroring delegate on
    /// the same store in this process.
    @MainActor
    static func sharedContainer() throws -> ModelContainer {
        guard let container = AppStoreBootstrap.shared().container else {
            throw AppError.database(AppLocalization.localized(
                "intent.error.store_unavailable",
                value: "Pawtrackr couldn't open its data. Open the app to see what happened."
            ))
        }
        return container
    }
}

// MARK: - Shortcuts
struct PawtrackrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckInPetIntent(),
            phrases: [
                "Check in a pet in \(.applicationName)",
                "Start session for \(\.$pet) in \(.applicationName)",
                "Check in \(\.$pet) with \(.applicationName)"
            ],
            shortTitle: "Check In Pet",
            systemImageName: "play.circle.fill"
        )
        
        AppShortcut(
            intent: GetBusinessStatsIntent(),
            phrases: [
                "How is my business doing today in \(.applicationName)",
                "Get my revenue in \(.applicationName)",
                "Show stats in \(.applicationName)"
            ],
            shortTitle: "Business Stats",
            systemImageName: "chart.bar.fill"
        )
    }
}
