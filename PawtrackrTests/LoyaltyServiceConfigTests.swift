import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class LoyaltyServiceConfigTests: XCTestCase {
    var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        DataMigrations.ensureLoyaltyDefaults(in: container.mainContext)
    }

    override func tearDownWithError() throws {
        container = nil
    }

    func testUpdateConfigPersistsFlatVisitMode() async throws {
        let service = LoyaltyService(modelContainer: container)

        try await service.updateConfig(
            earnMode: .flatPerVisit,
            pointsPerDollar: Decimal(1),
            pointsPerVisit: 20,
            redemptionThreshold: 100,
            isRewardsCatalogEnabled: true
        )

        let context = ModelContext(container)
        let config = try XCTUnwrap(try context.fetch(FetchDescriptor<LoyaltyConfig>()).first)
        XCTAssertEqual(config.earnMode, .flatPerVisit)
        XCTAssertEqual(config.pointsPerVisit, 20)
        XCTAssertEqual(config.redemptionThreshold, 100)
    }

    func testUpdateConfigMergesOnlyProvidedFields() async throws {
        let service = LoyaltyService(modelContainer: container)

        try await service.updateConfig(
            earnMode: .flatPerVisit,
            pointsPerDollar: Decimal(4),
            pointsPerVisit: 45,
            redemptionThreshold: 250,
            isRewardsCatalogEnabled: false
        )
        try await service.updateConfig(pointsPerVisit: 70)

        let context = ModelContext(container)
        let config = try XCTUnwrap(try context.fetch(FetchDescriptor<LoyaltyConfig>()).first)
        XCTAssertEqual(config.earnMode, .flatPerVisit)
        XCTAssertEqual(config.pointsPerDollar, Decimal(4))
        XCTAssertEqual(config.pointsPerVisit, 70)
        XCTAssertEqual(config.redemptionThreshold, 250)
        XCTAssertFalse(config.isRewardsCatalogEnabled)
    }

    func testCreateRewardTemplatePersistsReward() async throws {
        let service = LoyaltyService(modelContainer: container)

        try await service.createRewardTemplate(
            title: "Free Nail Trim",
            detail: "Redeem after five visits.",
            pointCost: 100,
            systemImage: "scissors",
            style: .care
        )

        let context = ModelContext(container)
        let rewards = try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        XCTAssertTrue(rewards.contains { $0.title == "Free Nail Trim" && $0.pointCost == 100 })
    }

    func testCreateRewardTemplateRejectsInvalidCost() async throws {
        let service = LoyaltyService(modelContainer: container)

        do {
            try await service.createRewardTemplate(
                title: "Bad Reward",
                detail: "Invalid",
                pointCost: 0,
                systemImage: "gift.fill",
                style: .credit
            )
            XCTFail("Zero-cost rewards must be rejected.")
        } catch let error as AppError {
            guard case .validation = error else {
                return XCTFail("Expected validation error, got \(error).")
            }
        }
    }

    func testReconcilesLegacyStarterRewardsWithoutChangingClientHistoryOrCustomRewards() async throws {
        let context = ModelContext(container)
        for reward in try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>()) { context.delete(reward) }
        let retired = LoyaltyRewardTemplate(title: "Deep-Conditioning Treatment", detail: "A premium coat-care add-on for a returning client.", pointCost: 200,
                                            systemImage: "drop.fill", styleRaw: "care", sortOrder: 0)
        let legacyCredit = LoyaltyRewardTemplate(title: "$10 Salon Credit", detail: "Apply toward the next completed checkout.", pointCost: 100,
                                                 systemImage: "ticket.fill", styleRaw: "credit", sortOrder: 1)
        let legacyVIP = LoyaltyRewardTemplate(title: "VIP Spa Package", detail: "Bundle a high-value add-on into the client's next visit.", pointCost: 500,
                                              systemImage: "sparkles", styleRaw: "vip", sortOrder: 2)
        let custom = LoyaltyRewardTemplate(title: "Birthday Gift", detail: "Owner-created", pointCost: 300,
                                           systemImage: "gift.fill", styleRaw: "care", sortOrder: 3)
        let client = Client(firstName: "Saved", lastName: "Points")
        client.loyaltyPoints = 128
        context.insert(retired)
        context.insert(legacyCredit)
        context.insert(legacyVIP)
        context.insert(custom)
        context.insert(client)
        context.insert(LoyaltyLedgerEntry(kind: .redeemed, points: -200, clientUUID: client.uuid, reason: retired.title))
        try context.save()

        let service = LoyaltyService(modelContainer: container)
        try await service.ensureDefaults()
        try await service.ensureDefaults()

        let fresh = ModelContext(container)
        let rewards = try fresh.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        XCTAssertEqual(rewards.count, 4)
        XCTAssertEqual(Set(rewards.map(\.title)), Set(["$10 Salon Credit", "$20 Salon Credit", "VIP Spa Package", "Birthday Gift"]))
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 128)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<LoyaltyLedgerEntry>()).first?.reason, "Deep-Conditioning Treatment")
    }

    func testReconciliationPreservesAnEditedStarterDefinition() async throws {
        let context = ModelContext(container)
        let edited = try XCTUnwrap(try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>()).first { $0.title == "$10 Salon Credit" })
        edited.detail = "Owner's custom description"
        edited.markModified()
        try context.save()

        try await LoyaltyService(modelContainer: container).ensureDefaults()

        let fresh = ModelContext(container)
        let rewards = try fresh.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        XCTAssertTrue(rewards.contains { $0.uuid == edited.uuid && $0.detail == "Owner's custom description" })
    }
}
