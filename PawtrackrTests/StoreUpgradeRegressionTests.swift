import XCTest
import SwiftData
@testable import Pawtrackr

/// Opens real stores written by shipped builds with today's model list — what
/// a user's device does on the first launch after an App Store update.
///
/// 1.0.2 shipped without this check. Its staged migration plan matched no 1.0.1
/// store, every upgrading user hit NSCocoaErrorDomain 134504, and the recovery
/// screen talked them into resetting. See PawtrackrTests/Fixtures/StoreFixtures.md for
/// how fixtures are captured.
final class StoreUpgradeRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreUpgradeRegressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testOpens101StoreWithEveryRecord() throws {
        let container = try makeContainer(at: copyFixture("Pawtrackr-1.0.1-build2"))
        let context = ModelContext(container)

        let names = try context.fetch(FetchDescriptor<Client>()).map { "\($0.firstName) \($0.lastName)" }
        XCTAssertEqual(Set(names), ["Ava Martinez", "Jordan Lee", "Rosa Upgradetest"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Pet>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Visit>()), 4)
        // Setup survives too, so the user lands in the app rather than onboarding.
        XCTAssertEqual(try context.fetch(FetchDescriptor<BusinessConfig>()).first?.isSetupComplete, true)
    }

    func testMigrated101StoreHoldsModelsAddedAfterItShipped() throws {
        let container = try makeContainer(at: copyFixture("Pawtrackr-1.0.1-build2"))
        let context = ModelContext(container)

        // The launch-time maintenance that touches the three loyalty tables
        // 1.0.1 never had.
        DataMigrations.ensureLoyaltyDefaults(in: context)
        DataMigrations.backfillLoyaltyLedger(in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoyaltyConfig>()), 1)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<LoyaltyRewardTemplate>()), 0)
        XCTAssertNoThrow(try context.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()))
    }

    func testMigrated101StoreReopensWithWritesIntact() throws {
        let storeURL = try copyFixture("Pawtrackr-1.0.1-build2")
        do {
            let context = ModelContext(try makeContainer(at: storeURL))
            context.insert(Client(firstName: "Post", lastName: "Upgrade"))
            try context.save()
        }

        let reopened = ModelContext(try makeContainer(at: storeURL))
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Client>()), 4)
    }

    func testClientRowCountReadsFixtureWithoutSidecarFiles() throws {
        // A lone WAL-mode store (no -wal/-shm) can't be opened read-only the
        // normal way; backup discovery must still count its clients.
        let storeURL = try copyFixture("Pawtrackr-1.0.1-build2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + "-shm"))

        XCTAssertEqual(StoreFileMigration.clientRowCount(in: storeURL), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + "-shm"), "Counting must not create files next to a backup.")
    }

    func testOpens102StoreWrittenThroughTheOldStagedPlan() throws {
        // 1.0.2 created this store with its staged migration plan. Dropping the
        // plan must not strand it.
        let storeURL = try copyFixture("Pawtrackr-1.0.2-build3")
        let context = ModelContext(try makeContainer(at: storeURL))

        let names = try context.fetch(FetchDescriptor<Client>()).map { "\($0.firstName) \($0.lastName)" }
        XCTAssertEqual(Set(names), ["Ava Martinez", "Jordan Lee", "Nina Afterreset"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Visit>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoyaltyConfig>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoyaltyRewardTemplate>()), 4)

        context.insert(Client(firstName: "Post", lastName: "Upgrade"))
        try context.save()
        let reopened = ModelContext(try makeContainer(at: storeURL))
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Client>()), 4)
    }

    // MARK: - Helpers

    func testLegacyStoreReopensWithExactQuantityLineTotalIntact() throws {
        let storeURL = try copyFixture("Pawtrackr-1.0.1-build2")
        var itemUUID: UUID!
        do {
            let context = ModelContext(try makeContainer(at: storeURL))
            let items = try context.fetch(FetchDescriptor<VisitItem>())
            XCTAssertTrue(items.allSatisfy { $0.reconciledLineTotal == nil })
            let item = try XCTUnwrap(items.first)
            itemUUID = item.uuid
            item.setQuantity(3)
            item.setReconciledLineTotal(10)
            try context.save()
        }
        let reopened = ModelContext(try makeContainer(at: storeURL))
        let item = try XCTUnwrap(reopened.fetch(FetchDescriptor<VisitItem>()).first { $0.uuid == itemUUID })
        XCTAssertEqual(item.quantity, 3)
        XCTAssertEqual(item.lineTotal, 10)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Client>()), 3)
    }

    /// Uses the same local configuration as the app at an isolated fixture URL.
    private func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(PawtrackrSchema.models)
        let configuration = LocalStoreConfiguration.make(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func copyFixture(_ name: String) throws -> URL {
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "sqlite"),
            "Fixture \(name).sqlite is missing from the test bundle."
        )
        let destination = directory.appendingPathComponent("Pawtrackr.store")
        try FileManager.default.copyItem(at: fixture, to: destination)
        return destination
    }
}
