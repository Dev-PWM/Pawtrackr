import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class AutomaticVisitLoyaltyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var client: Client!
    private var pet: Pet!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        context = container.mainContext
        client = Client(firstName: "Visit", lastName: "Rewards")
        pet = Pet(name: "Milo", species: .dog)
        pet.owner = client
        context.insert(client)
        context.insert(pet)
        try context.save()
    }

    func testCheckInDoesNotEarnEvenWithAnEarlyPayment() throws {
        let visit = makeVisit(payment: 80, completed: false)
        XCTAssertNil(try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: 80, in: context))
        XCTAssertEqual(client.loyaltyPoints, 0)
        XCTAssertEqual(visit.loyaltyPointsChange, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 0)
    }

    func testCompletedUnpaidVisitDoesNotEarn() throws {
        let visit = makeVisit(payment: nil, completed: true)
        XCTAssertNil(try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: 80, in: context))
        XCTAssertEqual(client.loyaltyPoints, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 0)
    }

    func testPartialPaymentDoesNotEarnUntilSettled() throws {
        let visit = makeVisit(payment: 40, completed: true)
        XCTAssertNil(try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: 80, in: context))
        XCTAssertEqual(client.loyaltyPoints, 0)
        visit.payment?.setAmount(80)
        try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: 80, in: context)
        XCTAssertEqual(client.loyaltyPoints, 80)
        XCTAssertEqual(visit.loyaltyPointsChange, 80)
    }

    func testZeroTotalVisitDoesNotEarnFlatPointsOrReturnBonus() throws {
        let visit = makeVisit(payment: 0, completed: true)
        let flat = LoyaltyConfigSnapshot(earnMode: .flatPerVisit, pointsPerDollar: 1, pointsPerVisit: 20, redemptionThreshold: 100, isRewardsCatalogEnabled: true)
        try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: 0, in: context, config: flat)
        XCTAssertEqual(client.loyaltyPoints, 0)
        XCTAssertEqual(visit.loyaltyPointsChange, 0)
    }

    func testPaymentRetryAcrossActorInstancesEarnsExactlyOnce() async throws {
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        let request = CheckoutRequest(visitUUID: visit.uuid, petUUID: pet.uuid, clientUUID: client.uuid,
                                      amount: 80, paymentMethod: .cash, externalReference: nil, sessionNotes: nil,
                                      behaviorTags: [], beforePhotoData: nil, afterPhotoData: nil,
                                      selectedServiceIDs: [], selectedAddOnIDs: [])
        _ = try await CheckoutTransactionActor(modelContainer: container).process(request)
        _ = try await CheckoutTransactionActor(modelContainer: container).process(request)
        let fresh = ModelContext(container)
        let savedClient = try XCTUnwrap(fresh.fetch(FetchDescriptor<Client>()).first)
        let savedVisit = try XCTUnwrap(fresh.fetch(FetchDescriptor<Visit>()).first)
        XCTAssertEqual(savedClient.loyaltyPoints, 80)
        XCTAssertEqual(savedVisit.loyaltyPointsChange, 80)
        XCTAssertNotNil(savedVisit.endedAt)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Payment>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 1)
    }

    func testSecondaryAwardPathReadsActorContextAndRejectsUnpaidVisit() async throws {
        let visit = makeVisit(payment: nil, completed: true)
        try context.save()
        try await LoyaltyService(modelContainer: container).applyPoints(for: visit)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 0)
    }

    func testDisplayedBalanceReadsCommittedActorAwardsAndRedemptions() async throws {
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        let displayed = LoyaltyBalanceState(points: client.loyaltyPoints)
        let request = CheckoutRequest(visitUUID: visit.uuid, petUUID: pet.uuid, clientUUID: client.uuid,
                                      amount: 120, paymentMethod: .cash, externalReference: nil, sessionNotes: nil,
                                      behaviorTags: [], beforePhotoData: nil, afterPhotoData: nil,
                                      selectedServiceIDs: [], selectedAddOnIDs: [])
        _ = try await CheckoutTransactionActor(modelContainer: container).process(request)
        await displayed.refresh(clientUUID: client.uuid, container: container)
        XCTAssertEqual(displayed.points, 120)
        XCTAssertNil(displayed.errorMessage)
        _ = try await LoyaltyService(modelContainer: container)
            .redeemReward(clientUUID: client.uuid, reward: LoyaltyReward.builtInCatalog[0])
        await displayed.refresh(clientUUID: client.uuid, container: container)
        XCTAssertEqual(displayed.points, 20)
    }

    func testRewardRedemptionPersistsAndCannotOverdrawOnRepeat() async throws {
        client.loyaltyPoints = 100
        try context.save()
        let service = LoyaltyService(modelContainer: container)
        let reward = LoyaltyReward.builtInCatalog[0]
        let newBalance = try await service.redeemReward(clientUUID: client.uuid, reward: reward)
        XCTAssertEqual(newBalance, 0)
        do {
            _ = try await service.redeemReward(clientUUID: client.uuid, reward: reward)
            XCTFail("A second redemption must not overdraw the committed balance")
        } catch let error as AppError {
            guard case .database = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 1)
    }

    func testDisabledRewardCannotBeRedeemedFromStaleScreen() async throws {
        client.loyaltyPoints = 100
        let template = LoyaltyRewardTemplate(reward: LoyaltyReward.builtInCatalog[0], sortOrder: 0)
        context.insert(template)
        try context.save()
        let displayedReward = template.displayReward
        let service = LoyaltyService(modelContainer: container)
        try await service.setRewardTemplate(uuid: template.uuid, isEnabled: false)
        do {
            _ = try await service.redeemReward(clientUUID: client.uuid, reward: displayedReward)
            XCTFail("A stale screen must not redeem a disabled reward")
        } catch let error as AppError {
            guard case .database = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 100)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 0)
    }

    func testCheckoutCreditReducesPaymentAndRecordsBothSidesExactlyOnce() async throws {
        client.loyaltyPoints = 120
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        let request = checkoutRequest(visit: visit, reward: LoyaltyReward.builtInCatalog[0], expected: 70)
        _ = try await CheckoutTransactionActor(modelContainer: container).process(request)
        _ = try await CheckoutTransactionActor(modelContainer: container).process(request)
        let fresh = ModelContext(container)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Visit>()).first)
        XCTAssertEqual(saved.total, 70)
        XCTAssertEqual(saved.payment?.amount, 70)
        XCTAssertEqual(saved.loyaltyCreditApplied, 10)
        XCTAssertEqual(saved.loyaltyRedeemedPoints, 100)
        XCTAssertEqual(saved.loyaltyRewardTitle, "$10 Salon Credit")
        XCTAssertEqual(saved.loyaltyPointsChange, 70)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 90)
        let entries = try fresh.fetch(FetchDescriptor<LoyaltyLedgerEntry>())
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.filter { $0.kind == .redeemed }.first?.points, -100)
        XCTAssertTrue(entries.allSatisfy { $0.visitUUID == visit.uuid })
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Payment>()), 1)
    }

    func testKeepingOldPointsHasNoExpiryOrBusinessBalanceCap() async throws {
        client.loyaltyPoints = 1_000_000
        let entry = LoyaltyLedgerEntry(kind: .earned, points: 1_000_000, clientUUID: client.uuid,
                                       createdAt: Date(timeIntervalSince1970: 0))
        context.insert(entry)
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 1_000_080)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Visit>()).first?.loyaltyRedeemedPoints, 0)
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<LoyaltyLedgerEntry>()).contains { $0.kind == .redeemed })
    }

    func testCannotSpendPointsThatThisVisitHasNotEarnedYet() async throws {
        client.loyaltyPoints = 0
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        do {
            _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit, reward: LoyaltyReward.builtInCatalog[0], expected: 70))
            XCTFail("Current visit earnings cannot fund a redemption before payment")
        } catch {}
        try assertRejectedCheckoutLeavesBalance(0)
    }

    func testChangedCreditAmountRejectsCheckoutWithoutSpendingOrPayment() async throws {
        client.loyaltyPoints = 100
        let template = LoyaltyRewardTemplate(reward: LoyaltyReward.builtInCatalog[0], sortOrder: 0)
        context.insert(template)
        let selected = template.displayReward
        template.creditAmount = 6
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        do {
            _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit, reward: selected, expected: 70))
            XCTFail("The displayed price must match the saved reward")
        } catch {}
        try assertRejectedCheckoutLeavesBalance(100)
    }

    func testCreditAboveSubtotalCannotConsumePoints() async throws {
        client.loyaltyPoints = 100
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        do {
            _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit, amount: 3, reward: LoyaltyReward.builtInCatalog[0], expected: 0))
            XCTFail("A partial credit must not consume the full point cost")
        } catch {}
        try assertRejectedCheckoutLeavesBalance(100)
    }

    func testServiceRewardRecordsChoiceWithoutChangingPaymentTotal() async throws {
        client.loyaltyPoints = 500
        let reward = LoyaltyReward.builtInCatalog[2]
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit, reward: reward, expected: 80))
        let fresh = ModelContext(container)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Visit>()).first)
        XCTAssertEqual(saved.payment?.amount, 80)
        XCTAssertEqual(saved.loyaltyRedeemedPoints, 500)
        XCTAssertEqual(saved.loyaltyCreditApplied, 0)
        XCTAssertEqual(saved.loyaltyRewardTitle, reward.title)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 80)
    }

    func testConcurrentConfirmationAcrossActorsSpendsAndEarnsOnlyOnce() async throws {
        client.loyaltyPoints = 100
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        let request = checkoutRequest(visit: visit, reward: LoyaltyReward.builtInCatalog[0], expected: 70)
        let first = CheckoutTransactionActor(modelContainer: container)
        let second = CheckoutTransactionActor(modelContainer: container)
        async let one = first.process(request)
        async let two = second.process(request)
        _ = try await (one, two)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 70)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 2)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Payment>()), 1)
    }

    func testConcurrentVisitsCannotOverdrawOneSavedBalance() async throws {
        client.loyaltyPoints = 100
        let firstVisit = makeVisit(payment: nil, completed: false)
        let secondVisit = makeVisit(payment: nil, completed: false)
        try context.save()
        let requests = [firstVisit, secondVisit].map { checkoutRequest(visit: $0, amount: 10, reward: LoyaltyReward.builtInCatalog[0], expected: 0) }
        let actors = [CheckoutTransactionActor(modelContainer: container), CheckoutTransactionActor(modelContainer: container)]
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<2 {
                group.addTask {
                    do { _ = try await actors[index].process(requests[index]); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Payment>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 1)
    }

    func testCustomCreditUsesExactDecimalCents() async throws {
        client.loyaltyPoints = 10
        let credit = Decimal(string: "1.11")!
        let template = LoyaltyRewardTemplate(title: "Small thank-you", detail: "Credit", pointCost: 10,
                                             systemImage: "gift", styleRaw: "credit", sortOrder: 0, creditAmount: credit)
        context.insert(template)
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit, amount: Decimal(string: "3.33")!, reward: template.displayReward, expected: Decimal(string: "2.22")!))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Visit>()).first?.payment?.amount, Decimal(string: "2.22"))
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 2)
    }

    private func checkoutRequest(visit: Visit, amount: Decimal = 80, reward: LoyaltyReward? = nil, expected: Decimal? = nil) -> CheckoutRequest {
        CheckoutRequest(visitUUID: visit.uuid, petUUID: pet.uuid, clientUUID: client.uuid,
                        amount: amount, paymentMethod: .cash, externalReference: nil, sessionNotes: nil,
                        behaviorTags: [], beforePhotoData: nil, afterPhotoData: nil,
                        selectedServiceIDs: [], selectedAddOnIDs: [], selectedLoyaltyReward: reward, expectedPaymentAmount: expected)
    }

    private func assertRejectedCheckoutLeavesBalance(_ balance: Int) throws {
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, balance)
        XCTAssertNil(try fresh.fetch(FetchDescriptor<Visit>()).first?.endedAt)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Payment>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 0)
    }

    func testReusedCheckoutActorReadsRedemptionFromAnotherContext() async throws {
        client.loyaltyPoints = 100
        let firstVisit = makeVisit(payment: nil, completed: false)
        try context.save()
        let actor = CheckoutTransactionActor(modelContainer: container)
        _ = try await actor.process(checkoutRequest(visit: firstVisit))
        _ = try await LoyaltyService(modelContainer: container).redeemReward(clientUUID: client.uuid, reward: LoyaltyReward.builtInCatalog[0])
        let secondVisit = makeVisit(payment: nil, completed: false)
        try context.save()
        _ = try await actor.process(checkoutRequest(visit: secondVisit))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 180,
                       "100 saved + 80 first visit − 100 redeemed + 100 returning visit")
    }

    func testReusedLoyaltyActorDoesNotOverwriteNewCheckoutEarnings() async throws {
        client.loyaltyPoints = 200
        let visit = makeVisit(payment: nil, completed: false)
        try context.save()
        let service = LoyaltyService(modelContainer: container)
        let options = try await service.checkoutOptions(clientUUID: client.uuid)
        XCTAssertEqual(options.points, 200)
        _ = try await service.redeemReward(clientUUID: client.uuid, reward: LoyaltyReward.builtInCatalog[0])
        _ = try await CheckoutTransactionActor(modelContainer: container).process(checkoutRequest(visit: visit))
        let balance = try await service.redeemReward(clientUUID: client.uuid, reward: LoyaltyReward.builtInCatalog[0])
        XCTAssertEqual(balance, 80, "200 saved − 100 used + 80 earned − 100 used")
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Client>()).first?.loyaltyPoints, 80)
    }

    /// Makes the lifecycle states independently testable without going through the UI.
    private func makeVisit(payment amount: Decimal?, completed: Bool) -> Visit {
        let visit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-3600))
        context.insert(visit)
        if completed { visit.markCheckedOut(total: 80) }
        if let amount {
            let payment = Payment(amount: amount, method: .cash)
            context.insert(payment)
            visit.attachPayment(payment)
        }
        return visit
    }
}
