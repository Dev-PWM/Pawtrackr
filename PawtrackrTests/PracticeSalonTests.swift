import XCTest
import SwiftData
@testable import Pawtrackr

/// The Academy's practice salon: an in-memory store with the sample clients
/// that the main window runs on while the tour is open. Whatever happens in
/// it must never reach the real salon.
@MainActor
final class PracticeSalonTests: XCTestCase {
    override func tearDown() {
        UserDefaults(suiteName: PracticeSalon.defaultsSuiteName)?
            .removePersistentDomain(forName: PracticeSalon.defaultsSuiteName)
        super.tearDown()
    }

    private func makeRealStore() throws -> ModelContainer {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func testOpeningSeedsAHandsOnSalon() throws {
        let salon = PracticeSalon()
        XCTAssertTrue(salon.open())
        let context = try XCTUnwrap(salon.session).container.mainContext

        let tourClient = try XCTUnwrap(SampleData.tourClient(in: context))
        XCTAssertEqual(tourClient.uuid, SampleData.avaClientID)
        let pets = tourClient.pets ?? []
        XCTAssertTrue(pets.contains { $0.name == "Milo" && $0.activeVisit != nil }, "Milo is in session for the Check Out mission.")
        XCTAssertTrue(pets.contains { $0.name == PracticeSalon.pepperName && $0.activeVisit == nil }, "Pepper waits for the Check In mission.")

        let tourContext = WalkthroughTourContext.resolve(in: context)
        XCTAssertTrue(tourContext.hasSampleClient)
        XCTAssertTrue(tourContext.hasActiveSampleVisit)
        XCTAssertFalse(tourContext.isExplainOnly, "Every stop is hands-on in the practice salon.")
        XCTAssertEqual(
            WalkthroughController.tour(for: .frontDeskGroomer, context: tourContext).map(\.id),
            WalkthroughController.tour(for: .frontDeskGroomer, context: .practice).map(\.id)
        )
        salon.close()
    }

    func testTheRealSalonIsNeverTouched() throws {
        let realStore = try makeRealStore()
        let real = realStore.mainContext
        real.insert(Client(firstName: "Rosa", lastName: "Diaz"))
        try real.save()
        let pricesBefore = Set(SamplePriceRecord.entries(userDefaults: .standard))

        let salon = PracticeSalon()
        XCTAssertTrue(salon.open())
        let practice = try XCTUnwrap(salon.session).container.mainContext
        practice.insert(Client(firstName: "Practice", lastName: "Only"))
        try practice.save()

        XCTAssertEqual(try real.fetchCount(FetchDescriptor<Client>()), 1, "Nothing from the practice salon lands in the real one.")
        XCTAssertEqual(try SampleData.sampleClientCount(in: real), 0)
        XCTAssertEqual(Set(SamplePriceRecord.entries(userDefaults: .standard)), pricesBefore, "Example prices are recorded only in the practice suite.")

        salon.close()
        let practiceDefaults = try XCTUnwrap(UserDefaults(suiteName: PracticeSalon.defaultsSuiteName))
        XCTAssertTrue(SamplePriceRecord.entries(userDefaults: practiceDefaults).isEmpty, "Closing clears the practice suite.")
        XCTAssertEqual(try real.fetchCount(FetchDescriptor<Client>()), 1)
    }

    func testOpeningTwiceKeepsTheSalonAndANewAcademyGetsAFreshOne() {
        let salon = PracticeSalon()
        XCTAssertFalse(salon.isOpen)
        XCTAssertTrue(salon.open())
        let first = salon.session?.id
        XCTAssertTrue(salon.open())
        XCTAssertEqual(salon.session?.id, first, "Opening an open salon keeps it.")

        salon.close()
        XCTAssertFalse(salon.isOpen)
        XCTAssertNil(salon.session)

        XCTAssertTrue(salon.open())
        XCTAssertNotEqual(salon.session?.id, first, "A new Academy starts from a fresh salon.")
        salon.close()
    }

    /// The window runs on the practice salon while it is open, and every
    /// place that could carry practice data out stays shut.
    func testTheWindowSwitchesStoresAndLeaksStayShut() throws {
        let root = try source("Pawtrackr/App/RootView.swift")
        XCTAssertTrue(root.contains(".modelContainer(practiceSalon.session?.container ?? modelContext.container)"))
        XCTAssertTrue(root.contains(".environment(\\.isPracticeSalon, practiceSalon.isOpen)"))
        XCTAssertTrue(root.contains("PracticeSalonBanner()"))

        let content = try source("Pawtrackr/App/ContentView.swift")
        XCTAssertTrue(content.contains(".id(practiceSalon?.session?.id)"), "Screens rebuild on the store they show.")
        XCTAssertTrue(content.contains("practiceSalon?.close()"), "The tour's end closes the practice salon.")

        XCTAssertTrue(try source("Pawtrackr/Features/Clients/ClientDetailView.swift").contains(".userActivity(\"com.pawtrackr.viewClient\", isActive: !isPracticeSalon)"))
        XCTAssertTrue(try source("Pawtrackr/Features/Clients/PetDetailView.swift").contains(".userActivity(\"com.pawtrackr.viewPet\", isActive: !isPracticeSalon)"))
        XCTAssertTrue(try source("Pawtrackr/Features/Dashboard/DashboardView.swift").contains("if isComplete && !isPracticeSalon"), "The practice checklist never retires the real one.")
    }

    private func source(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Pawtrackr.xcodeproj").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw XCTSkip("Repository sources aren't available.") }
            root = parent
        }
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
