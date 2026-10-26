//
//  VisitDeletionLoyaltyTests.swift
//  PawtrackrTests
//
//  Deleting a finished visit takes back its loyalty effect in the same save:
//  earned points come off, points spent on a reward there are refunded, the
//  balance never goes negative, and the ledger records one adjustment.
//

import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class VisitDeletionLoyaltyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var repository: VisitRepository!
    private var client: Client!
    private var pet: Pet!

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

    func testDeletingAPaidVisitTakesBackItsPoints() async throws {
        let visit = try await paidCheckout(total: 40)
        XCTAssertEqual(try committedBalance(), 20)
        let visitUUID = visit.uuid

        try await repository.deleteVisit(visit)

        XCTAssertEqual(try committedBalance(), 0)
        let adjustment = try XCTUnwrap(try adjustments().first)
        XCTAssertEqual(adjustment.points, -20)
        XCTAssertEqual(adjustment.balanceAfter, 0)
        XCTAssertEqual(adjustment.visitUUID, visitUUID)
        let summary = try XCTUnwrap(try insightSummaries().first)
        XCTAssertEqual(summary.visitCount, 0, "Retention must forget the deleted visit without a relaunch")
    }

    func testDeletingAVisitRefundsTheRewardPointsSpentThere() async throws {
        let visit = try await paidCheckout(total: 40)
        // The client had 100 points and spent them on a reward at this visit.
        let visitUUID = visit.uuid
        let writer = ModelContext(container)
        try XCTUnwrap(writer.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.uuid == visitUUID })).first).loyaltyRedeemedPoints = 100
        try writer.save()
        XCTAssertEqual(try committedBalance(), 20)

        try await repository.deleteVisit(visit)

        XCTAssertEqual(try committedBalance(), 100, "20 earned comes off, 100 spent comes back")
        XCTAssertEqual(try adjustments().map(\.points), [80])
    }

    func testBalanceNeverGoesNegativeWhenTheEarnedPointsWereAlreadySpent() async throws {
        let visit = try await paidCheckout(total: 40)
        try await setCommittedBalance(0)

        try await repository.deleteVisit(visit)

        XCTAssertEqual(try committedBalance(), 0)
        XCTAssertTrue(try adjustments().isEmpty, "Nothing changed, so nothing is recorded")
    }

    // MARK: - Fixtures

    /// A finished, fully paid visit, checked out through the repository so
    /// `LoyaltyService.applyPoints` awards it.
    private func paidCheckout(total: Decimal) async throws -> Visit {
        let now = Date.now
        let visit = try await repository.checkIn(pet: pet, date: now.addingTimeInterval(-3600))
        visit.addItem(title: "Bath", unitPrice: total)
        let payment = Payment(amount: total, method: .cash, paidAt: now)
        context.insert(payment)
        visit.attachPayment(payment)
        try await repository.checkOut(visit: visit, total: total, now: now)
        return visit
    }

    private func committedBalance() throws -> Int {
        let uuid = client.uuid
        let fresh = ModelContext(container)
        return try XCTUnwrap(fresh.fetch(FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == uuid })).first).loyaltyPoints
    }

    private func setCommittedBalance(_ points: Int) async throws {
        let uuid = client.uuid
        let writer = ModelContext(container)
        try XCTUnwrap(writer.fetch(FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == uuid })).first).loyaltyPoints = points
        try writer.save()
    }

    private func adjustments() throws -> [LoyaltyLedgerEntry] {
        let adjustedRaw = LoyaltyLedgerEntry.Kind.adjusted.rawValue
        return try ModelContext(container).fetch(FetchDescriptor<LoyaltyLedgerEntry>(
            predicate: #Predicate { $0.kindRaw == adjustedRaw }
        ))
    }

    private func insightSummaries() throws -> [ClientInsightSummary] {
        let uuid = client.uuid
        return try ModelContext(container).fetch(FetchDescriptor<ClientInsightSummary>(
            predicate: #Predicate { $0.clientUUID == uuid }
        ))
    }
}
