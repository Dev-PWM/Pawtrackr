import XCTest
import SwiftData
@testable import Pawtrackr

/// Full E2E scenario test: a groomer adds a Full Groom main service plus a $15 Nail Trim
/// add-on, charges via Zelle with a transaction reference, and the PDF receipt total must
/// match the line-item sum. Locks in the specific user journey the protocol audit named.
///
/// Note: the audit named `QualityControl/CheckoutFlowTests.swift`, but `QualityControl/`
/// is not in any test target (no `PBXFileSystemSynchronizedRootGroup` covers it) so tests
/// placed there would be dead code. This file lives in `PawtrackrTests/` to actually run.
@MainActor
final class CheckoutFlowTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var actor: CheckoutTransactionActor!
    var client: Client!
    var pet: Pet!
    var fullGroom: Service!
    var nailTrim: Service!

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

        // Real-world prices the audit named: $65 main + $15 add-on = $80 total.
        fullGroom = Service(name: "Full Groom", category: .groom, basePrice: Decimal(65))
        nailTrim = Service(name: "Nail Trim", category: .addOn, basePrice: Decimal(15))
        context.insert(fullGroom)
        context.insert(nailTrim)
        try context.save()

        actor = CheckoutTransactionActor(modelContainer: container)
        Formatters.updateCurrencySymbol("$")
    }

    override func tearDownWithError() throws {
        container = nil; context = nil; actor = nil
        client = nil; pet = nil; fullGroom = nil; nailTrim = nil
    }

    /// The audit's headline scenario: Full Groom + $15 Nail Trim, paid via Zelle with
    /// a transaction ID, must produce a PDF receipt whose total exactly equals $80.00.
    func testFullGroomPlusNailTrim_PaidByZelle_PDFTotalMatches() async throws {
        let visitUUID = UUID()
        let request = CheckoutRequest(
            visitUUID: visitUUID,
            petUUID: pet.uuid,
            clientUUID: client.uuid,
            amount: Decimal(string: "80.00")!,
            paymentMethod: .zelle,
            externalReference: "ZELLE-48291",
            sessionNotes: "Standard full groom + nails",
            behaviorTags: [],
            beforePhotoData: nil,
            afterPhotoData: nil,
            selectedServiceIDs: [fullGroom.persistentModelID],
            selectedAddOnIDs: [nailTrim.persistentModelID]
        )

        let result = try await actor.process(request)

        // 1. Result reports the right total + payment metadata
        XCTAssertEqual(result.total, Decimal(string: "80.00"))
        XCTAssertEqual(result.visitID.entityName, "Visit")

        // 2. Persisted visit (fresh context to bust the main cache) has the right shape
        let freshContext = ModelContext(container)
        let visit = try XCTUnwrap(
            try freshContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == visitUUID })).first
        )
        XCTAssertEqual(visit.total, Decimal(string: "80.00"))
        XCTAssertEqual((visit.items ?? []).count, 2)
        XCTAssertEqual(visit.payment?.method, .zelle)
        XCTAssertEqual(visit.payment?.amount, Decimal(string: "80.00"))
        XCTAssertEqual(visit.payment?.externalReference, "ZELLE-48291")

        // 3. PDF receipt snapshot — the consumer that the audit explicitly named.
        let snapshot = PDFReceiptService.shared.makeSnapshot(for: visit)
        XCTAssertEqual(snapshot.totalString, "$80.00",
            "Receipt total must match line-item sum (Full Groom $65 + Nail Trim $15).")
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items.map(\.name).sorted(), ["Full Groom", "Nail Trim"])
        XCTAssertTrue(snapshot.payment?.infoLine.contains("Zelle") ?? false)
        XCTAssertEqual(snapshot.payment?.referenceLine, "Reference: ZELLE-48291")

        // 4. PDF bytes render and are non-trivial
        let pdfData = PDFReceiptService.render(snapshot: snapshot)
        XCTAssertGreaterThan(pdfData.count, 1024)
        XCTAssertEqual(String(data: pdfData.prefix(5), encoding: .ascii), "%PDF-")
    }

    /// Idempotency: a duplicate `process` call for the same checkout must not produce
    /// a second Payment row or a duplicate audit transaction.
    func testFullGroomPlusNailTrim_DuplicateProcess_StaysAtomic() async throws {
        let visitUUID = UUID()
        let request = CheckoutRequest(
            visitUUID: visitUUID,
            petUUID: pet.uuid,
            clientUUID: client.uuid,
            amount: Decimal(string: "80.00")!,
            paymentMethod: .zelle,
            externalReference: "ZELLE-48291",
            sessionNotes: nil,
            behaviorTags: [],
            beforePhotoData: nil,
            afterPhotoData: nil,
            selectedServiceIDs: [fullGroom.persistentModelID],
            selectedAddOnIDs: [nailTrim.persistentModelID]
        )

        let first = try await actor.process(request)
        let second = try await actor.process(request)

        XCTAssertEqual(first.endedAt, second.endedAt,
            "Idempotent retry must return the original completion timestamp.")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Payment>()).count, 1,
            "Duplicate process must NOT create a second Payment row.")
        XCTAssertEqual(try context.fetch(FetchDescriptor<CheckoutTransaction>()).count, 1,
            "Idempotency key must collapse retries to one audit row.")
    }

    func testCheckoutTransactionAccruesClientLoyaltyPoints() async throws {
        let visitUUID = UUID()
        client.loyaltyPoints = 120
        try context.save()

        let request = CheckoutRequest(
            visitUUID: visitUUID,
            petUUID: pet.uuid,
            clientUUID: client.uuid,
            amount: Decimal(string: "85.50")!,
            paymentMethod: .cash,
            externalReference: nil,
            sessionNotes: nil,
            behaviorTags: [],
            beforePhotoData: nil,
            afterPhotoData: nil,
            selectedServiceIDs: [fullGroom.persistentModelID],
            selectedAddOnIDs: [nailTrim.persistentModelID]
        )

        _ = try await actor.process(request)

        let clientUUID = client.uuid
        let freshContext = ModelContext(container)
        let refreshedClient = try XCTUnwrap(
            try freshContext.fetch(FetchDescriptor<Client>(predicate: #Predicate<Client> { $0.uuid == clientUUID })).first
        )
        let refreshedVisit = try XCTUnwrap(
            try freshContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == visitUUID })).first
        )

        XCTAssertEqual(refreshedVisit.loyaltyPointsChange, 20)
        XCTAssertEqual(refreshedClient.loyaltyPoints, 140)

        // The checkout must also leave an auditable `.earned` ledger row.
        let entries = try freshContext.fetch(
            FetchDescriptor<LoyaltyLedgerEntry>(predicate: #Predicate<LoyaltyLedgerEntry> { $0.visitUUID == visitUUID })
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .earned)
        XCTAssertEqual(entries.first?.points, 20)
        XCTAssertEqual(entries.first?.balanceAfter, 140)
        XCTAssertEqual(entries.first?.clientUUID, clientUUID)
        XCTAssertEqual(entries.first?.reason, "Buddy")
    }

    /// Gold membership and a recent visit retain the same fixed 20-point award.
    func testGoldTierRebookingClientEarnsSameTwentyPoints() async throws {
        let priorVisit = Visit(pet: pet)
        context.insert(priorVisit)
        priorVisit.loyaltyPointsChange = 1_500
        priorVisit.setEndedAt(Date(timeIntervalSinceNow: -10 * 86_400))
        try context.save()

        let visitUUID = UUID()
        let request = CheckoutRequest(
            visitUUID: visitUUID,
            petUUID: pet.uuid,
            clientUUID: client.uuid,
            amount: Decimal(string: "85.50")!,
            paymentMethod: .cash,
            externalReference: nil,
            sessionNotes: nil,
            behaviorTags: [],
            beforePhotoData: nil,
            afterPhotoData: nil,
            selectedServiceIDs: [fullGroom.persistentModelID],
            selectedAddOnIDs: []
        )

        _ = try await actor.process(request)

        let freshContext = ModelContext(container)
        let refreshedVisit = try XCTUnwrap(
            try freshContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == visitUUID })).first
        )
        XCTAssertEqual(refreshedVisit.loyaltyPointsChange, 20,
            "Tier and return timing do not change the fixed visit award.")
    }

    /// Editing a price preserves the fixed award and its one earned ledger row.
    func testReprocessedCheckoutUpsertsEarnedLedgerEntry() async throws {
        let visit = Visit(pet: pet)
        context.insert(visit)
        visit.markCheckedOut(total: Decimal(80))
        let payment = Payment(amount: 80, method: .cash)
        context.insert(payment)
        visit.attachPayment(payment)
        try context.save()

        try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: Decimal(80), in: context)
        try context.save()
        XCTAssertEqual(visit.loyaltyPointsChange, 20)
        XCTAssertEqual(client.loyaltyPoints, 20)

        // The groomer corrects the price; points remain unchanged.
        payment.setAmount(100)
        visit.markCheckedOut(total: 100)
        try LoyaltyCheckoutProcessor.applyEarnings(visit: visit, pet: pet, total: Decimal(100), in: context)
        try context.save()

        let visitUUID = visit.uuid
        let entries = try context.fetch(
            FetchDescriptor<LoyaltyLedgerEntry>(predicate: #Predicate<LoyaltyLedgerEntry> { $0.visitUUID == visitUUID })
        )
        XCTAssertEqual(entries.count, 1, "Re-processing must upsert, not duplicate, the earned entry.")
        XCTAssertEqual(entries.first?.points, 20)
        XCTAssertEqual(visit.loyaltyPointsChange, 20)
        XCTAssertEqual(client.loyaltyPoints, 20,
            "Correcting the price must preserve the original visit award.")
    }

    func testLoyaltyProcessor_ReprocessesFlatVisitModeIdempotently() throws {
        let visit = Visit(pet: pet)
        visit.markCheckedOut(total: 80)
        let payment = Payment(amount: 120, method: .cash)
        context.insert(payment)
        visit.attachPayment(payment)
        context.insert(visit)
        try context.save()

        let config = LoyaltyConfigSnapshot(
            earnMode: .flatPerVisit,
            pointsPerDollar: Decimal(1),
            pointsPerVisit: 20,
            redemptionThreshold: 100,
            isRewardsCatalogEnabled: true
        )

        try LoyaltyCheckoutProcessor.applyEarnings(
            visit: visit,
            pet: pet,
            total: Decimal(80),
            in: context,
            now: .now,
            config: config
        )
        try LoyaltyCheckoutProcessor.applyEarnings(
            visit: visit,
            pet: pet,
            total: Decimal(120),
            in: context,
            now: .now,
            config: config
        )

        XCTAssertEqual(visit.loyaltyPointsChange, 20)
        XCTAssertEqual(client.loyaltyPoints, 20)
    }

    /// Zelle without a transaction reference must be rejected by validation, so the
    /// audit-mandated "Confirm button disabled unless reference entered" promise holds.
    func testZellePaymentWithoutReference_FailsValidation() {
        // We exercise the Method's reference validation rather than the full VM, which is
        // covered elsewhere. This locks in the specific contract that Zelle requires a ref.
        XCTAssertNotNil(Payment.Method.zelle.validationMessage(for: ""),
            "Zelle with empty reference must surface a validation message.")
        XCTAssertNil(Payment.Method.zelle.validationMessage(for: "ZELLE-48291"),
            "Zelle with a non-empty reference must clear validation.")
        XCTAssertTrue(Payment.Method.zelle.requiresExternalReference)
    }
}
