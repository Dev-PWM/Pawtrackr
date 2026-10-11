import XCTest
import SwiftData
@testable import Pawtrackr

final class MigrationsTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    func testEnsureServiceCatalog_CreatesDefaults() throws {
        // Initial state: potentially empty or seeded by container init
        // We'll clear and run the migration
        let existing = try context.fetch(FetchDescriptor<Service>())
        for s in existing { context.delete(s) }
        try context.save()
        
        DataMigrations.ensureServiceCatalog(in: context)
        
        let services = try context.fetch(FetchDescriptor<Service>())
        XCTAssertGreaterThan(services.count, 5)
        XCTAssertTrue(services.contains(where: { $0.name == "Full Package" }))
    }

    func testEnsureServiceCatalog_DisablesObsoleteBasicGroom() throws {
        let obsolete = Service(
            name: "Basic Groom",
            category: .groom,
            systemIcon: "scissors",
            basePrice: Decimal(50),
            isEnabled: true
        )
        context.insert(obsolete)
        try context.save()

        DataMigrations.ensureServiceCatalog(in: context)

        let services = try context.fetch(FetchDescriptor<Service>())
        let fetched = try XCTUnwrap(services.first(where: { $0.name == "Basic Groom" }))
        XCTAssertFalse(fetched.isEnabled)
        XCTAssertNil(fetched.basePrice)
    }

    func testEnsureMessageTemplates_AddsMissingDefaultsToExistingInstall() throws {
        let custom = MessageTemplate(title: "Custom Update", content: "Custom body")
        context.insert(custom)
        try context.save()

        DataMigrations.ensureMessageTemplates(in: context)

        let titles = Set(try context.fetch(FetchDescriptor<MessageTemplate>()).map(\.title))
        XCTAssertTrue(titles.contains("Custom Update"))
        XCTAssertTrue(titles.contains("Ready for Pickup"))
        XCTAssertTrue(titles.contains("Appointment Reminder"))
        XCTAssertTrue(titles.contains("Running Late"))
        XCTAssertTrue(titles.contains("Post-Visit Follow-up"))
    }

    func testEnsureLoyaltyDefaults_CreatesConfigAndRewardTemplates() throws {
        DataMigrations.ensureLoyaltyDefaults(in: context)

        let configs = try context.fetch(FetchDescriptor<LoyaltyConfig>())
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?.earnMode, .pointsPerDollar)
        XCTAssertEqual(configs.first?.pointsPerDollar, Decimal(1))
        XCTAssertEqual(configs.first?.pointsPerVisit, 20)
        XCTAssertEqual(configs.first?.redemptionThreshold, 100)

        let rewards = try context.fetch(
            FetchDescriptor<LoyaltyRewardTemplate>(sortBy: [SortDescriptor(\.sortOrder)])
        )
        XCTAssertEqual(rewards.count, LoyaltyReward.builtInCatalog.count)
        XCTAssertEqual(rewards.first?.pointCost, 100)
        XCTAssertEqual(rewards.first?.title, "$10 Salon Credit")
    }

    func testEnsureLoyaltyDefaults_IsIdempotent() throws {
        DataMigrations.ensureLoyaltyDefaults(in: context)
        DataMigrations.ensureLoyaltyDefaults(in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<LoyaltyConfig>()).count, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>()).count,
            LoyaltyReward.builtInCatalog.count
        )
    }

    func testEnsureLoyaltyDefaults_CollapsesAllDuplicateConfigs() throws {
        context.insert(LoyaltyConfig())
        context.insert(LoyaltyConfig())
        context.insert(LoyaltyConfig())
        try context.save()

        DataMigrations.ensureLoyaltyDefaults(in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<LoyaltyConfig>()).count, 1)
    }

    func testEnsureLoyaltyDefaults_MergesDuplicateConfigsFieldWise() throws {
        let baseline = LoyaltyConfig()
        baseline.createdAt = Date(timeIntervalSince1970: 10)
        baseline.updatedAt = Date(timeIntervalSince1970: 10)

        let earningRules = LoyaltyConfig()
        earningRules.setEarnMode(.flatPerVisit)
        earningRules.setPointsPerVisit(80)
        earningRules.createdAt = Date(timeIntervalSince1970: 20)
        earningRules.updatedAt = Date(timeIntervalSince1970: 20)

        let rewardRules = LoyaltyConfig()
        rewardRules.setPointsPerDollar(Decimal(3))
        rewardRules.setRedemptionThreshold(275)
        rewardRules.setRewardsCatalogEnabled(false)
        rewardRules.createdAt = Date(timeIntervalSince1970: 30)
        rewardRules.updatedAt = Date(timeIntervalSince1970: 30)

        context.insert(baseline)
        context.insert(earningRules)
        context.insert(rewardRules)
        try context.save()

        DataMigrations.ensureLoyaltyDefaults(in: context)

        let configs = try context.fetch(FetchDescriptor<LoyaltyConfig>())
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(config.earnMode, .flatPerVisit)
        XCTAssertEqual(config.pointsPerDollar, Decimal(3))
        XCTAssertEqual(config.pointsPerVisit, 80)
        XCTAssertEqual(config.redemptionThreshold, 275)
        XCTAssertFalse(config.isRewardsCatalogEnabled)
    }
    
    func testCoercePets_StandardizesGenders() throws {
        let pet = Pet(name: "Test", species: .dog)
        // Manually set a 'bad' state if possible (though enum prevents it, 
        // older data might have been different)
        context.insert(pet)
        try context.save()
        
        DataMigrations.coercePets(in: context)
        
        // Refresh and verify
        let fetched = try context.fetch(FetchDescriptor<Pet>()).first!
        XCTAssertTrue(fetched.gender == .male || fetched.gender == .female)
    }
}
