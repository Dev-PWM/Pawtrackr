import XCTest
import SwiftData
@testable import Pawtrackr

/// Direct unit tests for VisitRepository — the check-in / check-out / save / delete surface
/// touched by the dashboard, client-detail, and active-visit screens.
@MainActor
final class VisitRepositoryTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var repository: VisitRepository!
    var client: Client!
    var pet: Pet!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        client = Client(firstName: "Jane", lastName: "Doe", phone: "5551234567")
        context.insert(client)
        pet = Pet(name: "Buddy", species: .dog)
        pet.owner = client
        context.insert(pet)
        try context.save()

        repository = VisitRepository(modelContext: context, eventBus: GlobalEventBus())
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        repository = nil
        client = nil
        pet = nil
    }

    func testCheckIn_DebugLogging() async throws {
        let started = Date()
        let visit = try await repository.checkIn(pet: pet, date: started)
        
        XCTAssertNotNil(visit.modelContext)
        XCTAssertTrue(visit.isActive)
    }

    func testCheckIn_VisitAppearsInPetVisitsRelationship() async throws {
        _ = try await repository.checkIn(pet: pet, date: .now)
        XCTAssertEqual((pet.visits ?? []).count, 1)
        XCTAssertEqual((pet.visits ?? []).first?.endedAt, nil)
    }

    func testCheckIn_PersistsAndIsFetchable() async throws {
        let created = try await repository.checkIn(pet: pet, date: .now)
        let uuid = created.uuid
        let descriptor = FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == uuid })
        XCTAssertEqual(try context.fetch(descriptor).count, 1)
    }

    func testCheckIn_ReusesExistingActiveVisitForPet() async throws {
        let first = try await repository.checkIn(pet: pet, date: .now)
        let second = try await repository.checkIn(pet: pet, date: .now.addingTimeInterval(60))

        XCTAssertEqual(first.uuid, second.uuid)
        let activeVisits = try context.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.endedAt == nil }))
            .filter { $0.pet?.uuid == pet.uuid }
        XCTAssertEqual(activeVisits.count, 1)
    }

    func testCheckIn_DoesNotReuseVisitCompletedInAnotherContext() async throws {
        let first = try await repository.checkIn(pet: pet, date: .now.addingTimeInterval(-3600))

        let checkoutContext = ModelContext(container)
        let checkoutVisit = try XCTUnwrap(checkoutContext.model(for: first.persistentModelID) as? Visit)
        checkoutVisit.markCheckedOut(total: Decimal(30), now: .now)
        try checkoutContext.save()

        let second = try await repository.checkIn(pet: pet, date: .now.addingTimeInterval(60))

        XCTAssertNotEqual(first.uuid, second.uuid)
        let freshContext = ModelContext(container)
        let activeVisits = try freshContext.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.endedAt == nil }
        ))
        XCTAssertEqual(activeVisits.filter { $0.pet?.uuid == pet.uuid }.count, 1)
    }

    func testCheckIn_AssignsDeterministicSessionToken() async throws {
        let started = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 19, hour: 10))!
        let visit = try await repository.checkIn(pet: pet, date: started)

        XCTAssertEqual(visit.sessionToken, Visit.makeSessionToken(petUUID: pet.uuid, startedAt: started))
    }

    func testCheckIn_PostsVisitDidStartNotification() async throws {
        let exp = expectation(forNotification: .visitDidStart, object: nil, handler: nil)
        _ = try await repository.checkIn(pet: pet, date: .now)
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testCheckOut_SetsEndedAtAndTotal() async throws {
        let visit = try await repository.checkIn(pet: pet, date: .now)
        visit.addItem(title: "Bath", unitPrice: Decimal(30))
        let endedAt = Date()

        try await repository.checkOut(visit: visit, total: Decimal(30), now: endedAt)

        XCTAssertNotNil(visit.endedAt)
        XCTAssertTrue(visit.isCompleted)
        XCTAssertEqual(visit.total, Decimal(string: "30.00"))
    }

    func testCheckOut_RebuildsDaySummaryForThatDay() async throws {
        let visit = try await repository.checkIn(pet: pet, date: .now)
        visit.addItem(title: "Bath", unitPrice: Decimal(30))
        let payment = Payment(amount: Decimal(30), method: .cash, paidAt: .now)
        context.insert(payment)
        visit.attachPayment(payment)

        try await repository.checkOut(visit: visit, total: Decimal(30), now: .now)

        let day = Calendar.current.startOfDay(for: try XCTUnwrap(visit.endedAt))
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.day == day }))
        let aggregate = SummaryUpdater.collapsedDayAggregates(from: summaries)[day]
        XCTAssertEqual(aggregate?.revenue, Decimal(string: "30.00"))
        XCTAssertEqual(aggregate?.visitCount, 1)
    }

    func testCheckOut_PostsVisitDidCompleteNotification() async throws {
        let visit = try await repository.checkIn(pet: pet, date: .now)
        let exp = expectation(forNotification: .visitDidComplete, object: nil, handler: nil)
        try await repository.checkOut(visit: visit, total: Decimal(25), now: .now)
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testSaveVisit_PersistsToStore() async throws {
        // `Visit(pet: pet)` may implicitly join `pet`'s context — that's fine.
        // What we care about is that after `saveVisit`, the row exists in the store.
        let visit = Visit(pet: pet)

        try await repository.saveVisit(visit)

        XCTAssertNotNil(visit.modelContext)
        let uuid = visit.uuid
        let descriptor = FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == uuid })
        XCTAssertEqual(try context.fetch(descriptor).count, 1)
    }

    func testDeleteVisit_RemovesFromStoreAndRebuildsDaySummary() async throws {
        let visit = try await repository.checkIn(pet: pet, date: .now)
        visit.addItem(title: "Bath", unitPrice: Decimal(30))
        try await repository.checkOut(visit: visit, total: Decimal(30), now: .now)
        let day = Calendar.current.startOfDay(for: try XCTUnwrap(visit.endedAt))
        // The delete runs in a fresh context; don't read the UI model afterwards.
        let visitUUID = visit.uuid

        try await repository.deleteVisit(visit)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == visitUUID })).count, 0)

        let summaries = try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.day == day }))
        let aggregate = SummaryUpdater.collapsedDayAggregates(from: summaries)[day]
        XCTAssertEqual(aggregate?.revenue ?? .zero, .zero)
        XCTAssertEqual(aggregate?.visitCount ?? 0, 0)
    }

    func testFetchVisits_RespectsPredicateAndLimit() async throws {
        for offset in 0..<5 {
            let visit = Visit(pet: pet, startedAt: .now.addingTimeInterval(Double(offset) * 60))
            context.insert(visit)
        }
        try context.save()

        let petUUID = pet.uuid
        let predicate = #Predicate<Visit> { $0.pet?.uuid == petUUID }
        let result = try await repository.fetchVisits(predicate: predicate, sortBy: [], limit: 3)
        XCTAssertEqual(result.count, 3)
    }
}
