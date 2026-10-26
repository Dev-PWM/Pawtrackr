//
//  InsightsPeriodAndRetentionTests.swift
//  PawtrackrTests
//
//  The 7/30/90-day selector governs every period card (revenue, payment mix,
//  categories), the revenue chart spans the whole period, and retention
//  forgets deleted clients and removed pets without waiting for a relaunch.
//

import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class InsightsPeriodAndRetentionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var dataStore: DataStoreService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        dataStore = DataStoreService(container: container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        dataStore = nil
        try super.tearDownWithError()
    }

    // MARK: - Period

    func testPaymentMixAndCategoriesFollowTheSelectedPeriod() async throws {
        let pet = try seedPet()
        try checkOut(pet: pet, daysAgo: 1, amount: 40, method: .cash, category: .groom)
        try checkOut(pet: pet, daysAgo: 20, amount: 60, method: .creditCard, category: .package)

        let vm = InsightsViewModel(dataStore: dataStore, eventBus: GlobalEventBus())
        await vm.refresh()
        XCTAssertEqual(vm.totalRevenue, 100)
        XCTAssertEqual(paymentTotal(vm), 100)
        XCTAssertEqual(vm.totalCategoryVisits, 2)

        vm.revenuePeriodDays = 7
        await vm.refreshRevenue()

        XCTAssertEqual(vm.totalRevenue, 40)
        XCTAssertEqual(paymentTotal(vm), 40, "Payment mix must cover the same days as revenue")
        XCTAssertEqual(vm.paymentMethodDistribution.map(\.method), [.cash])
        XCTAssertEqual(vm.categoryDistribution.map(\.name), [Service.Category.groom.rawValue])
    }

    func testRevenueWindowSpansEveryDayOfThePeriod() async throws {
        let pet = try seedPet()
        try checkOut(pet: pet, daysAgo: 0, amount: 25, method: .cash, category: .groom)

        let vm = InsightsViewModel(dataStore: dataStore, eventBus: GlobalEventBus())
        vm.revenuePeriodDays = 7
        await vm.refresh()

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let window = try XCTUnwrap(vm.revenueWindow)
        XCTAssertEqual(window.lowerBound, cal.date(byAdding: .day, value: -6, to: today))
        XCTAssertEqual(window.upperBound, cal.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(vm.revenueSeries.count, 1, "Only days with sales have bars; the window adds the empty ones")
    }

    // MARK: - Retention

    func testDeletedClientStopsCountingInRetentionWithoutARelaunch() async throws {
        let kept = try seedPet(firstName: "Kept")
        try checkOut(pet: kept, daysAgo: 2, amount: 30, method: .cash, category: .groom)
        try checkOut(pet: kept, daysAgo: 1, amount: 30, method: .cash, category: .groom)
        let deleted = try seedPet(firstName: "Gone")
        try checkOut(pet: deleted, daysAgo: 1, amount: 30, method: .cash, category: .groom)
        SummaryUpdater.rebuildAllSummaries(in: context)

        let actor = InsightsActor(modelContainer: container)
        let before = try await actor.fetchClientInsights()
        XCTAssertEqual(before.retentionRate, 0.5, accuracy: 0.0001)

        let clientID = try XCTUnwrap(deleted.owner?.persistentModelID)
        try await ClientRepository(modelContainer: container).deleteClient(id: clientID)

        let after = try await InsightsActor(modelContainer: container).fetchClientInsights()
        XCTAssertEqual(after.retentionRate, 1, accuracy: 0.0001, "Only the remaining, recurring client counts")
        XCTAssertEqual(after.retentionSeries.map(\.value), [1, 0])
    }

    func testRemovedPetDoesNotMakeItsOwnerAChurnRisk() async throws {
        let pet = try seedPet()
        // A dog's cadence is 30 days, so a visit 90 days ago is overdue.
        try checkOut(pet: pet, daysAgo: 90, amount: 50, method: .cash, category: .groom)
        SummaryUpdater.rebuildAllSummaries(in: context)
        let overdue = try await InsightsActor(modelContainer: container).fetchClientInsights()
        XCTAssertEqual(overdue.churnRiskCount, 1)

        pet.archivedAt = .now
        try context.save()
        SummaryUpdater.rebuildAllSummaries(in: context)

        let removed = try await InsightsActor(modelContainer: container).fetchClientInsights()
        XCTAssertEqual(removed.churnRiskCount, 0)
    }

    // MARK: - Fixtures

    private func paymentTotal(_ vm: InsightsViewModel) -> Decimal {
        vm.paymentMethodDistribution.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func seedPet(firstName: String = "Test") throws -> Pet {
        let owner = Client(firstName: firstName, lastName: "Owner", phone: "5550100100")
        context.insert(owner)
        let pet = Pet(name: "\(firstName) Dog", species: .dog)
        pet.owner = owner
        context.insert(pet)
        try context.save()
        return pet
    }

    /// A finished, paid visit at noon `daysAgo` days back, with its day summary rebuilt.
    private func checkOut(
        pet: Pet,
        daysAgo: Int,
        amount: Decimal,
        method: Payment.Method,
        category: Service.Category
    ) throws {
        let cal = Calendar.current
        let day = try XCTUnwrap(cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: .now)))
        // Noon, or now for today, so a visit never lands in the future.
        let ended = daysAgo == 0 ? Date.now : day.addingTimeInterval(12 * 3600)

        let service = Service(name: "\(category.rawValue) service", basePrice: amount)
        service.category = category
        context.insert(service)
        let visit = Visit(pet: pet, startedAt: ended.addingTimeInterval(-3600))
        context.insert(visit)
        let item = VisitItem.from(service: service, visit: visit)
        context.insert(item)
        visit.items = [item]
        let payment = Payment(amount: amount, method: method, paidAt: ended)
        context.insert(payment)
        visit.attachPayment(payment)
        visit.markCheckedOut(total: amount, now: ended)
        try context.save()
        SummaryUpdater.rebuildDay(for: ended, in: context)
    }
}
