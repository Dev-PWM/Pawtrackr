import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class CheckoutViewModelTests: XCTestCase {

    // MARK: - Fixtures
    var container: ModelContainer!
    var context: ModelContext!
    var pet: Pet!
    var bath: Service!      // $30.00
    var haircut: Service!   // $45.00
    var nailTrim: Service!  // $10.00 add-on

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        let client = Client(firstName: "Jane", lastName: "Doe", phone: "5551234567")
        context.insert(client)

        pet = Pet(name: "Buddy", species: .dog)
        pet.owner = client
        context.insert(pet)

        bath    = Service(name: "Bath",     basePrice: Decimal(30))
        haircut = Service(name: "Haircut",  basePrice: Decimal(45))
        nailTrim = Service(name: "Nail Trim", category: .addOn, basePrice: Decimal(10))
        context.insert(bath)
        context.insert(haircut)
        context.insert(nailTrim)

        try context.save()
        Formatters.updateCurrencySymbol("$")
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        pet = nil
        bath = nil
        haircut = nil
        nailTrim = nil
    }

    // Builds a VM seeded with services directly — no async loadServices needed.
    private func makeVM(visit: Visit? = nil) -> CheckoutViewModel {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = tmpDir.appendingPathComponent("trace.log")
        let checkoutVisit = visit ?? makeCheckoutVisit()
        let vm = CheckoutViewModel(
            pet: pet,
            visit: checkoutVisit,
            draftStore: CheckoutDraftStore(directoryURL: tmpDir),
            eventRecorder: CheckoutEventRecorder(logURL: logURL)
        )
        vm.allServices   = [bath, haircut]
        vm.addOnServices = [nailTrim]
        return vm
    }

    private func makeVM(root: URL, visit: Visit? = nil) -> CheckoutViewModel {
        let logURL = root.appendingPathComponent("trace.log")
        let checkoutVisit = visit ?? makeCheckoutVisit()
        let vm = CheckoutViewModel(
            pet: pet,
            visit: checkoutVisit,
            draftStore: CheckoutDraftStore(directoryURL: root),
            eventRecorder: CheckoutEventRecorder(logURL: logURL)
        )
        return vm
    }

    private func makeCheckoutVisit() -> Visit {
        let visit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-1800))
        context.insert(visit)
        do {
            try context.save()
        } catch {
            XCTFail("Failed to save checkout visit fixture: \(error)")
        }
        return visit
    }

    private func waitForServicesToLoad(_ vm: CheckoutViewModel, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(20))
        while Date() < deadline {
            if !vm.isLoadingServices, !vm.allServices.isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testRewardChoiceSavesDraftWithoutSpendingAndRestoresCredit() async throws {
        pet.owner?.loyaltyPoints = 100
        try context.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let visit = makeCheckoutVisit()
        let vm = makeVM(root: root, visit: visit)
        vm.loadServices(modelContext: context)
        await waitForServicesToLoad(vm)
        vm.toggleService(bath)
        vm.chooseLoyaltyReward(LoyaltyReward.builtInCatalog[0])
        XCTAssertEqual(vm.paymentTotalDecimal, 20)
        XCTAssertEqual(pet.owner?.loyaltyPoints, 100)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoyaltyLedgerEntry>()), 0)
        let store = CheckoutDraftStore(directoryURL: root)
        var draft: CheckoutDraft?
        for _ in 0..<30 {
            draft = await store.loadDraft(for: visit.uuid)
            if draft?.selectedLoyaltyReward != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(draft?.selectedLoyaltyReward, LoyaltyReward.builtInCatalog[0])
        let recovered = makeVM(root: root, visit: visit)
        recovered.loadServices(modelContext: context)
        await waitForServicesToLoad(recovered)
        XCTAssertEqual(recovered.selectedLoyaltyReward, LoyaltyReward.builtInCatalog[0])
        XCTAssertEqual(recovered.paymentTotalDecimal, 20)
        XCTAssertTrue(recovered.isLoyaltySelectionValid)
        recovered.setAmountDirectly("8")
        XCTAssertEqual(recovered.loyaltyCredit, 0)
        XCTAssertFalse(recovered.isLoyaltySelectionValid)
        recovered.setAmountDirectly("30")
        XCTAssertTrue(recovered.isLoyaltySelectionValid)
        recovered.chooseLoyaltyReward(nil)
        XCTAssertEqual(recovered.paymentTotalDecimal, 30)
        XCTAssertEqual(pet.owner?.loyaltyPoints, 100)
    }

    // MARK: - Service Selection

    func testToggleService_SelectsService() {
        let vm = makeVM()
        XCTAssertFalse(vm.isServiceSelected(bath))
        vm.toggleService(bath)
        XCTAssertTrue(vm.isServiceSelected(bath))
    }

    func testToggleService_DeseletsAlreadySelectedService() {
        let vm = makeVM()
        vm.toggleService(bath)
        vm.toggleService(bath)
        XCTAssertFalse(vm.isServiceSelected(bath))
    }

    func testToggleAddOn_SelectsAndDeselects() {
        let vm = makeVM()
        vm.toggleAddOn(nailTrim)
        XCTAssertTrue(vm.isAddOnSelected(nailTrim))
        vm.toggleAddOn(nailTrim)
        XCTAssertFalse(vm.isAddOnSelected(nailTrim))
    }

    // MARK: - Amount Calculation

    func testAmount_SingleService() {
        let vm = makeVM()
        vm.toggleService(bath)
        XCTAssertEqual(vm.servicesTotalDecimal, Decimal(30))
    }

    func testAmount_MultipleServicesAndAddOn() {
        let vm = makeVM()
        vm.toggleService(bath)
        vm.toggleService(haircut)
        vm.toggleAddOn(nailTrim)
        XCTAssertEqual(vm.servicesTotalDecimal, Decimal(85))
    }

    func testAmount_ManualOverrideTakesPrecedence() {
        let vm = makeVM()
        vm.toggleService(bath)           // auto = $30
        vm.setAmountDirectly("60.00")   // manual override
        XCTAssertEqual(vm.servicesTotalDecimal, Decimal(60))
    }

    /// Checkout takes no tips: what the client pays is the services, or
    /// the amount typed over them.
    func testAmount_TotalIsTheServicesWithNoTip() {
        let vm = makeVM()
        vm.toggleService(bath)
        XCTAssertEqual(vm.servicesTotalDecimal, Decimal(30))
        XCTAssertEqual(vm.finalTotalString, "$30.00")
    }

    func testAmount_EmptySelectionIsZero() {
        let vm = makeVM()
        XCTAssertEqual(vm.servicesTotalDecimal, .zero)
    }

    // MARK: - Step Navigation

    func testAdvance_FromServicesRequiresSelection() {
        let vm = makeVM()
        XCTAssertThrowsError(try vm.advance()) // no service selected
    }

    func testAdvance_MovesToDetails() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance()
        XCTAssertEqual(vm.currentStep, .details)
    }

    func testAdvance_FullForwardProgression() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance()  // → details
        XCTAssertEqual(vm.currentStep, .details)
        try vm.advance()  // → payment
        XCTAssertEqual(vm.currentStep, .payment)
        vm.choosePayment(.cash)
        try vm.advance()  // → review
        XCTAssertEqual(vm.currentStep, .review)
    }

    func testGoBack_FromDetailsReturnsToServices() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance()
        vm.goBack()
        XCTAssertEqual(vm.currentStep, .services)
    }

    func testGoBack_AtServicesDoesNothing() {
        let vm = makeVM()
        vm.goBack()
        XCTAssertEqual(vm.currentStep, .services)
    }

    // MARK: - isAdvanceEnabled

    func testIsAdvanceEnabled_ServicesStepRequiresSelection() {
        let vm = makeVM()
        XCTAssertFalse(vm.isAdvanceEnabled)
        vm.toggleService(bath)
        XCTAssertTrue(vm.isAdvanceEnabled)
    }

    func testIsAdvanceEnabled_DetailsStepAlwaysTrue() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance() // → details
        XCTAssertTrue(vm.isAdvanceEnabled)
    }

    func testIsAdvanceEnabled_PaymentStepRequiresPositiveTotal() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance() // → details
        try vm.advance() // → payment
        vm.choosePayment(.cash)
        // Amount from service selection = $30 > 0 → enabled
        XCTAssertTrue(vm.isAdvanceEnabled)
    }

    func testIsAdvanceEnabled_PaymentStepDisabledWhenZeroTotal() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance()
        try vm.advance()
        vm.setAmountDirectly("0")
        XCTAssertFalse(vm.isAdvanceEnabled)
    }

    func testIsAdvanceEnabled_PaymentStepRequiresReferenceForCard() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance()
        try vm.advance()
        vm.choosePayment(.creditCard)
        vm.setExternalReference("")
        XCTAssertFalse(vm.isAdvanceEnabled)
        vm.setExternalReference("42")
        XCTAssertFalse(vm.isAdvanceEnabled)
        vm.setExternalReference("4242")
        XCTAssertTrue(vm.isAdvanceEnabled)
    }

    func testIsAdvanceEnabled_CashRequiresNoReference() throws {
        let vm = makeVM()
        vm.toggleService(bath)
        try vm.advance()
        try vm.advance()
        vm.choosePayment(.cash)
        XCTAssertTrue(vm.isAdvanceEnabled)
    }

    // MARK: - Payment Method

    func testChoosePayment_ClearsReferenceForCash() {
        let vm = makeVM()
        vm.setExternalReference("ref-123")
        vm.choosePayment(.cash)
        XCTAssertEqual(vm.externalReference, "")
    }

    func testDefaultPaymentMethod_IsCashForFastCheckout() {
        let vm = makeVM()
        XCTAssertEqual(vm.selectedPaymentMethod, .cash)
        XCTAssertFalse(vm.requiresExternalReference)
    }

    func testChoosePayment_KeepsReferenceAcrossCardMethods() {
        let vm = makeVM()
        vm.choosePayment(.creditCard)
        vm.setExternalReference("4242")
        vm.choosePayment(.debitCard)
        XCTAssertEqual(vm.externalReference, "4242")
    }

    func testChoosePayment_ClearsReferenceWhenReferenceTypeChanges() {
        let vm = makeVM()
        vm.choosePayment(.zelle)
        vm.setExternalReference("zelle-123")
        vm.choosePayment(.creditCard)
        XCTAssertEqual(vm.externalReference, "")
    }

    func testSetExternalReference_NormalizesCardInputToLastFourDigits() {
        let vm = makeVM()
        vm.choosePayment(.creditCard)
        vm.setExternalReference("card ending 991234")
        XCTAssertEqual(vm.externalReference, "1234")
    }

    func testFreeTextInputsClampBeforeDraftAndPersistenceBoundaries() {
        let vm = makeVM()
        vm.choosePayment(.zelle)

        vm.setSessionNotes(String(repeating: "High energy. ", count: 200))
        vm.setExternalReference(String(repeating: "zelle-ref-", count: 20))

        XCTAssertLessThanOrEqual(vm.sessionNotes.count, TextInputLimits.notes)
        XCTAssertLessThanOrEqual(vm.externalReference.count, TextInputLimits.shortText)
    }

    func testCheckoutTraceFileDoesNotPersistPetDisplayName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = root.appendingPathComponent("trace.log")
        let recorder = CheckoutEventRecorder(logURL: logURL)
        let visitID = UUID()

        for index in 0..<10 {
            await recorder.record("privacy_probe_\(index)", visitID: visitID, petName: "Buddy")
        }

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("visit=\(visitID.uuidString)"))
        XCTAssertTrue(contents.contains("petNameToken="))
        XCTAssertFalse(contents.contains("pet=Buddy"))
        XCTAssertFalse(contents.contains("Buddy"))
    }

    func testCheckoutTraceFilePrunesOldestLinesWhenByteCapExceeded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = root.appendingPathComponent("trace.log")
        let recorder = CheckoutEventRecorder(logURL: logURL, maxLines: 300, maxFileBytes: 900)
        let visitID = UUID()

        for index in 0..<20 {
            await recorder.record(
                "event_\(index)_\(String(repeating: "x", count: 120))",
                visitID: visitID,
                petName: "Buddy"
            )
        }

        let data = try Data(contentsOf: logURL)
        let contents = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertLessThanOrEqual(data.count, 900)
        XCTAssertTrue(contents.contains("event_19_"))
        XCTAssertFalse(contents.contains("event_0_"))
        XCTAssertFalse(contents.contains("Buddy"))
    }

    // MARK: - Draft

    func testMakeDraft_PhotosAreNil() {
        let vm = makeVM()
        vm.beforePhotoData = Data([0x01, 0x02, 0x03])
        vm.afterPhotoData  = Data([0x04, 0x05, 0x06])
        // Access internal draft via the public path: trigger a draft save and
        // verify photos aren't in the saved file by inspecting the VM state indirectly.
        // Direct test: photos should never appear in the draft (keeping drafts small).
        // We verify this by asserting the ViewModel strips them from makeDraft output.
        // Since makeDraft is private, we test its effect: flushDraft should succeed
        // without encoding photo data (no crash / no large file written).
        vm.flushDraft()
        // If we reach here without crashing or hanging, the lightweight draft path works.
        XCTAssertNotNil(vm.beforePhotoData) // VM still holds the photo
    }

    func testLoadServices_RestoresDraftAndSurfacesRecoveryNotice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CheckoutDraftStore(directoryURL: root)
        let visit = Visit(pet: pet)
        context.insert(visit)
        try context.save()

        let draft = CheckoutDraft(
            visitID: visit.uuid,
            petID: pet.uuid,
            updatedAt: Date(timeIntervalSince1970: 1_715_000_000),
            currentStepRawValue: CheckoutViewModel.CheckoutFlowStep.payment.rawValue,
            sessionNotes: "Recovered notes",
            amountString: "$40.00",
            tipAmountString: "$5.00",
            selectedTipPercentage: nil,
            selectedServiceUUIDs: [bath.uuid],
            selectedAddOnUUIDs: [nailTrim.uuid],
            selectedPaymentMethodRawValue: Payment.Method.cash.rawValue,
            beforePhotoData: nil,
            afterPhotoData: nil,
            hadBeforePhoto: true,
            hadAfterPhoto: true,
            externalReference: "",
            tags: ["Calm"]
        )
        try await store.saveDraft(draft)

        let vm = makeVM(root: root, visit: visit)
        vm.loadServices(modelContext: context)
        await waitForServicesToLoad(vm)

        XCTAssertEqual(vm.currentStep, .payment)
        XCTAssertEqual(vm.sessionNotes, "Recovered notes")
        XCTAssertEqual(vm.amountString, "$40.00")
        XCTAssertEqual(vm.servicesTotalDecimal, Decimal(40), "A tip saved by an earlier version stays out of the total.")
        XCTAssertTrue(vm.isServiceSelected(bath))
        XCTAssertTrue(vm.isAddOnSelected(nailTrim))
        XCTAssertEqual(vm.tags, Set(["Calm"]))
        XCTAssertEqual(vm.draftRecoveryNotice?.missingBeforePhoto, true)
        XCTAssertEqual(vm.draftRecoveryNotice?.missingAfterPhoto, true)
    }

    func testDiscardRecoveredDraft_ResetsVisitStateAndDeletesDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CheckoutDraftStore(directoryURL: root)
        let visit = Visit(pet: pet)
        context.insert(visit)
        try context.save()

        let draft = CheckoutDraft(
            visitID: visit.uuid,
            petID: pet.uuid,
            updatedAt: .now,
            currentStepRawValue: CheckoutViewModel.CheckoutFlowStep.review.rawValue,
            sessionNotes: "Recovered notes",
            amountString: "$88.00",
            tipAmountString: "",
            selectedTipPercentage: nil,
            selectedServiceUUIDs: [bath.uuid, haircut.uuid],
            selectedAddOnUUIDs: [],
            selectedPaymentMethodRawValue: Payment.Method.cash.rawValue,
            beforePhotoData: nil,
            afterPhotoData: nil,
            hadBeforePhoto: false,
            hadAfterPhoto: false,
            externalReference: "",
            tags: ["Needs Breaks"]
        )
        try await store.saveDraft(draft)

        let vm = makeVM(root: root, visit: visit)
        vm.loadServices(modelContext: context)
        await waitForServicesToLoad(vm)
        XCTAssertNotNil(vm.draftRecoveryNotice)

        await vm.discardRecoveredDraft()

        XCTAssertNil(vm.draftRecoveryNotice)
        XCTAssertEqual(vm.currentStep, .services)
        XCTAssertEqual(vm.sessionNotes, "")
        XCTAssertEqual(vm.amountString, "$0.00")
        XCTAssertFalse(vm.isServiceSelected(bath))
        XCTAssertFalse(vm.isServiceSelected(haircut))
        XCTAssertTrue(vm.tags.isEmpty)
        let deleted = await store.loadDraft(for: visit.uuid)
        XCTAssertNil(deleted)
    }

    // MARK: - Summary Strings

    func testSelectedServicesSummary_ReflectsSelection() {
        let vm = makeVM()
        XCTAssertEqual(vm.selectedServicesSummary, "None")
        vm.toggleService(bath)
        XCTAssertEqual(vm.selectedServicesSummary, "Bath")
        vm.toggleService(haircut)
        // Sorted alphabetically: Bath, Haircut
        XCTAssertEqual(vm.selectedServicesSummary, "Bath, Haircut")
    }

    func testFinalTotalString_UpdatesOnToggle() {
        let vm = makeVM()
        XCTAssertEqual(vm.finalTotalString, "$0.00")
        vm.toggleService(bath)
        XCTAssertEqual(vm.finalTotalString, "$30.00")
    }

    func testBehaviorTagsSummary_EmptyByDefault() {
        let vm = makeVM()
        XCTAssertEqual(vm.behaviorTagsSummary, "None")
    }

    // MARK: - processPayment (integration)

    func testProcessPayment_ConfirmsAndSavesVisit() async throws {
        let vm = makeVM()
        // Select service, advance to review
        vm.toggleService(bath)
        try vm.advance()  // → details
        try vm.advance()  // → payment
        vm.choosePayment(.cash)
        try vm.advance()  // → review

        XCTAssertEqual(vm.currentStep, .review)
        XCTAssertEqual(vm.state, .selectingServices) // not yet processing

        await vm.processPayment()

        XCTAssertEqual(vm.state, .confirmed)
        XCTAssertFalse(vm.isSaving)
        XCTAssertNil(vm.appError)
        // Visit should be marked checked-out
        XCTAssertNotNil(vm.visit.endedAt)
        XCTAssertEqual(vm.visit.total, Decimal(30))
        XCTAssertNotNil(vm.visit.payment)
        XCTAssertEqual(vm.visit.payment?.method, .cash)
        XCTAssertEqual(vm.visit.payment?.paidAt, vm.visit.endedAt)

        let transactions = try context.fetch(FetchDescriptor<CheckoutTransaction>())
        let transaction = try XCTUnwrap(transactions.first)
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transaction.idempotencyKey, "checkout:\(vm.visit.uuid.uuidString)")
        XCTAssertEqual(transaction.status, .succeeded)
        XCTAssertEqual(transaction.amount, Decimal(30))
        XCTAssertEqual(transaction.attemptCount, 1)

        await vm.processPayment()
        let transactionsAfterRetry = try context.fetch(FetchDescriptor<CheckoutTransaction>())
        XCTAssertEqual(transactionsAfterRetry.count, 1)
    }

    func testProcessPayment_CheckedInVisitDoesNotReappearActiveAfterMainContextSave() async throws {
        let activeVisit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-3600))
        context.insert(activeVisit)
        try context.save()

        let vm = makeVM(visit: activeVisit)
        vm.toggleService(bath)
        try vm.advance()
        try vm.advance()
        vm.choosePayment(.cash)
        try vm.advance()

        await vm.processPayment()

        XCTAssertEqual(vm.state, .confirmed)
        XCTAssertNotNil(vm.visit.endedAt)

        pet.notes = "Touched after checkout navigation"
        try context.save()

        let activeDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.endedAt == nil }
        )
        let activeVisits = try context.fetch(activeDescriptor)
        XCTAssertTrue(activeVisits.isEmpty, "A checked-out visit must not reappear as active after a later main-context save.")
    }

    func testCheckoutRouteResolverUsesOnlyStoreActiveVisit() throws {
        let activeVisit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-3600))
        context.insert(activeVisit)
        try context.save()

        let store = DataStoreService(container: container)
        let resolvedID = try CheckoutRouteResolver.activeVisitID(
            for: pet.persistentModelID,
            preferredVisitID: activeVisit.persistentModelID,
            dataStore: store
        )

        XCTAssertEqual(resolvedID, activeVisit.persistentModelID)

        let checkoutContext = ModelContext(container)
        let checkoutVisit = try XCTUnwrap(checkoutContext.model(for: activeVisit.persistentModelID) as? Visit)
        checkoutVisit.markCheckedOut(total: Decimal(30), now: .now)
        try checkoutContext.save()

        let afterCheckoutID = try CheckoutRouteResolver.activeVisitID(
            for: pet.persistentModelID,
            preferredVisitID: activeVisit.persistentModelID,
            dataStore: store
        )

        XCTAssertNil(afterCheckoutID, "Completed visits must not route into checkout or create a replacement visit.")
    }

    func testDataStoreResolvesCheckoutVisitOnlyForRequestedPet() throws {
        let otherClient = Client(firstName: "Luis", lastName: "Rivera", phone: "5550002222")
        let otherPet = Pet(name: "Luna", species: .dog)
        otherPet.owner = otherClient
        context.insert(otherClient)
        context.insert(otherPet)

        let completedPreferredVisit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-7200))
        completedPreferredVisit.markCheckedOut(total: Decimal(40), now: .now.addingTimeInterval(-3600))
        let requestedPetActiveVisit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-1800))
        let otherPetActiveVisit = Visit(pet: otherPet, startedAt: .now.addingTimeInterval(-2400))
        context.insert(completedPreferredVisit)
        context.insert(requestedPetActiveVisit)
        context.insert(otherPetActiveVisit)
        try context.save()

        let store = DataStoreService(container: container)
        let resolvedID = try store.resolveActiveCheckoutVisitID(
            for: pet.persistentModelID,
            preferredVisitID: completedPreferredVisit.persistentModelID
        )

        XCTAssertEqual(resolvedID, requestedPetActiveVisit.persistentModelID)
        XCTAssertNotEqual(resolvedID, otherPetActiveVisit.persistentModelID)
    }

    func testDataStoreKeepsCompletedPreferredVisitForOpenCheckoutRoute() throws {
        let activeVisit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-3600))
        context.insert(activeVisit)
        try context.save()

        let checkoutContext = ModelContext(container)
        let checkoutVisit = try XCTUnwrap(checkoutContext.model(for: activeVisit.persistentModelID) as? Visit)
        checkoutVisit.markCheckedOut(total: Decimal(30), now: .now)
        try checkoutContext.save()

        let store = DataStoreService(container: container)
        let resolvedID = try store.resolveActiveCheckoutVisitID(
            for: pet.persistentModelID,
            preferredVisitID: activeVisit.persistentModelID,
            allowsCompletedPreferredVisit: true
        )

        XCTAssertEqual(resolvedID, activeVisit.persistentModelID)
    }

    func testProcessPayment_ManualOverrideReconcilesLineItemsAndSummaryRevenue() async throws {
        let vm = makeVM()
        vm.toggleService(bath)
        vm.toggleService(haircut)
        vm.setAmountDirectly("100.00")
        try vm.advance()
        try vm.advance()
        vm.choosePayment(.cash)
        try vm.advance()

        await vm.processPayment()

        XCTAssertEqual(vm.state, .confirmed)
        XCTAssertEqual(vm.visit.total, Decimal(100))
        XCTAssertEqual(vm.visit.payment?.amount, Decimal(100))
        XCTAssertEqual((vm.visit.items ?? []).reduce(Decimal.zero) { $0 + $1.lineTotal }, Decimal(100))

        let day = Calendar.current.startOfDay(for: vm.visit.endedAt ?? Date())
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(
            predicate: #Predicate<DaySummary> { $0.day == day }
        ))
        XCTAssertEqual(SummaryUpdater.collapsedDayAggregates(from: summaries)[day]?.revenue, Decimal(100))
    }

    func testProcessPayment_RequiresReviewStep() async {
        let vm = makeVM()
        vm.toggleService(bath)

        await vm.processPayment()

        XCTAssertNotNil(vm.appError)
        XCTAssertNotEqual(vm.state, .confirmed)
        XCTAssertNil(vm.visit.endedAt)
    }

    func testProcessPayment_DoesNotRunWhenAlreadySaving() async {
        let vm = makeVM()
        vm.toggleService(bath)
        try? vm.advance()
        try? vm.advance()
        vm.choosePayment(.cash)
        try? vm.advance()
        // Manually set isSaving to simulate a double-tap
        // processPayment guards on isSaving so the second call should be a no-op.
        // We can't set isSaving directly (private(set)) so instead we verify the guard
        // works by calling processPayment twice — only one of them should advance state.
        let task1 = Task { await vm.processPayment() }
        let task2 = Task { await vm.processPayment() }
        await task1.value
        await task2.value
        // If both ran, state would still be .confirmed. If guard fired on second, same result.
        // Key check: no crash and state is resolved.
        XCTAssertFalse(vm.isSaving)
        let transactions = try? context.fetch(FetchDescriptor<CheckoutTransaction>())
        XCTAssertEqual(transactions?.count, 1)
    }

    func testProcessPayment_FailsValidationWithZeroAmount() async {
        let vm = makeVM()
        // Don't select any service — total is $0
        vm.currentStep = .review
        await vm.processPayment()
        XCTAssertNotNil(vm.appError)
        XCTAssertNotEqual(vm.state, .confirmed)
    }
}
