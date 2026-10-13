import XCTest
import SwiftData
@testable import Pawtrackr

/// Replaying the guided tour on a salon with real clients must never create
/// or change real data. The tour runs on the real local store, so
/// these tests drive the same functions the app uses: the tour context and
/// steps ContentView builds, the client its route opens, and the checkout
/// calls CheckoutView makes for each tour stop.
@MainActor
final class WalkthroughReplaySafetyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var draftDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        draftDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: draftDirectory)
        // Seeding records the example prices it set; don't leave them behind.
        UserDefaults.standard.removeObject(forKey: SamplePriceRecord.userDefaultsKey)
        container = nil
        context = nil
        try super.tearDownWithError()
    }

    // MARK: - Tour context

    func testTourContextTellsSampleAndRealClientsApartByUUIDOnly() throws {
        let empty = WalkthroughTourContext.resolve(in: context)
        XCTAssertFalse(empty.hasSampleClient)
        XCTAssertFalse(empty.hasRealClients)

        XCTAssertTrue(try DemoDataSeeder.seedIfNeeded(in: context))
        XCTAssertEqual(WalkthroughTourContext.resolve(in: context), WalkthroughTourContext(hasSampleClient: true, hasRealClients: false))

        // Same name as a sample client, but a real row.
        context.insert(Client(firstName: "Ava", lastName: "Martinez"))
        try context.save()
        let resolved = WalkthroughTourContext.resolve(in: context)
        XCTAssertTrue(resolved.hasSampleClient)
        XCTAssertTrue(resolved.hasRealClients)
        XCTAssertTrue(resolved.isExplainOnly)
    }

    func testWithRealClientsEveryStepOnlyExplains() {
        let context = WalkthroughTourContext(hasSampleClient: true, hasRealClients: true)
        for role in OnboardingRole.allCases {
            let steps = WalkthroughController.tour(for: role, context: context)
            XCTAssertTrue(steps.contains { $0.anchor == .cdCheckIn }, "The check-in stop is still taught.")
            XCTAssertFalse(steps.contains { $0.requiresTargetAction }, "\(role): every stop has a Next button.")
            XCTAssertFalse(steps.contains { $0.allowsTargetInteraction },
                           "\(role): no tap reaches Check In, Check Out or the New Client form's Create.")
        }
    }

    func testWithoutASampleClientTheTourOpensNoClientAndNoCheckout() {
        let context = WalkthroughTourContext(hasSampleClient: false, hasRealClients: true)
        for role in OnboardingRole.allCases {
            let steps = WalkthroughController.tour(for: role, context: context)
            XCTAssertFalse(steps.contains { $0.route == .demoClientDetail }, "\(role)")
            XCTAssertFalse(steps.contains { $0.presents == .checkout }, "\(role)")
            XCTAssertFalse(steps.isEmpty)
        }
        // The Academy still ends in Settings, where it can be replayed.
        XCTAssertEqual(WalkthroughController.tour(for: .ownerManager, context: context).last?.anchor, .setAbout)
    }

    func testLookOnlyCopyDoesNotInviteATapOnCreateAndStaysShort() {
        defer { UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride) }
        let explainOnly = WalkthroughTourContext(hasSampleClient: true, hasRealClients: true)
        for (language, invitation) in [(AppLanguageOverride.en, "Tap Create"), (AppLanguageOverride.es, "Toca Crear")] {
            UserDefaults.standard.set(language.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
            let steps = WalkthroughController.tour(for: .ownerManager, context: explainOnly)
            let save = steps.first { $0.anchor == .ncSave }
            XCTAssertNotNil(save)
            XCTAssertFalse(save?.purpose.contains(invitation) ?? true, "\(language): \(save?.purpose ?? "")")
            for step in steps {
                XCTAssertLessThanOrEqual(step.directive.count, 86, "\(language) \(step.anchor)")
                XCTAssertLessThanOrEqual(step.purpose.count, 190, "\(language) \(step.anchor)")
                XCTAssertLessThanOrEqual(step.coachTip?.count ?? 0, 150, "\(language) \(step.anchor)")
                for text in [step.directive, step.purpose] + [step.coachTip].compactMap(\.self) {
                    XCTAssertFalse(text.contains(";") || text.contains(" — "), "\(language) \(step.anchor): \(text)")
                }
            }
        }
    }

    func testAPracticeStoreKeepsTheHandsOnTour() {
        let practice = WalkthroughTourContext(hasSampleClient: true, hasRealClients: false)
        let steps = WalkthroughController.tour(for: .ownerManager, context: practice)
        // Same stops as the catalog, in the catalog's screen order, less the
        // ones the owner's curriculum leaves out, with hands-on flags intact.
        let ownerCatalog = WalkthroughController.fullTour().filter { !$0.excludedRoles.contains(.ownerManager) }
        XCTAssertEqual(steps.map(\.id), ownerCatalog.map(\.id))
        let catalog = Dictionary(uniqueKeysWithValues: WalkthroughController.fullTour().map { ($0.id, $0) })
        for step in steps {
            XCTAssertEqual(step, catalog[step.id], step.id)
        }
        XCTAssertEqual(steps.first { $0.anchor == .cdCheckIn }?.requiresTargetAction, true)
    }

    // MARK: - Replay on a real salon

    func testReplayOnANonEmptyStorePersistsNoVisit() async throws {
        XCTAssertTrue(try DemoDataSeeder.seedIfNeeded(in: context))

        // The salon's real client: one pet waiting to be checked in, and one
        // checked in right now.
        let owner = Client(firstName: "Rosa", lastName: "Diaz", phone: "3125550199")
        let waiting = Pet(name: "Pepper", species: .dog)
        let inSession = Pet(name: "Coco", species: .cat)
        for pet in [waiting, inSession] { pet.owner = owner }
        owner.pets = [waiting, inSession]
        context.insert(owner)
        context.insert(waiting)
        context.insert(inSession)
        let realVisit = Visit(pet: inSession, startedAt: .now.addingTimeInterval(-1800))
        context.insert(realVisit)
        inSession.visits = [realVisit]
        let bath = Service(name: "Replay Bath", basePrice: 40)
        context.insert(bath)
        try context.save()

        let before = try counts()

        for role in OnboardingRole.allCases {
            try await replayTour(role: role, bath: bath)
        }

        XCTAssertEqual(try counts(), before, "Replay saved no visit, payment, checkout or client.")
        XCTAssertNil(realVisit.endedAt, "The real visit in progress was not checked out.")
        XCTAssertNil(realVisit.payment)
        XCTAssertNil(waiting.activeVisit, "The real pet was not checked in.")
        let drafts = try FileManager.default.contentsOfDirectory(atPath: draftDirectory.path)
        XCTAssertTrue(drafts.isEmpty, "No checkout draft was written: \(drafts)")

        // Once the sample visit has been checked out, the Check In stop has a
        // pet it could check in. Replay still starts no visit.
        let sampleVisit = try XCTUnwrap(try context.fetch(FetchDescriptor<Visit>()).first { $0.uuid == SampleData.miloActiveVisitID })
        sampleVisit.markCheckedOut(total: 50)
        try context.save()
        let beforeSecondReplay = try counts()

        for role in OnboardingRole.allCases {
            try await replayTour(role: role, bath: bath)
        }

        XCTAssertEqual(try counts(), beforeSecondReplay, "Replay started no visit, not even on a sample pet.")
    }

    func testCheckoutInTourPreviewSavesNoPaymentAndNoDraft() async throws {
        let owner = Client(firstName: "Rosa", lastName: "Diaz")
        let pet = Pet(name: "Pepper", species: .dog)
        pet.owner = owner
        owner.pets = [pet]
        context.insert(owner)
        context.insert(pet)
        let visit = Visit(pet: pet, startedAt: .now.addingTimeInterval(-1800))
        context.insert(visit)
        let bath = Service(name: "Replay Bath", basePrice: 40)
        context.insert(bath)
        try context.save()

        let checkout = makeCheckout(pet: pet, visit: visit, services: [bath])
        checkout.beginWalkthroughPreview()
        checkout.toggleService(bath)
        checkout.setAmountDirectly("40")
        checkout.choosePayment(.cash)
        checkout.showStepForWalkthrough(.review)
        XCTAssertEqual(checkout.currentStep, .review)
        XCTAssertTrue(checkout.isConfirmEnabled, "Outside the tour this checkout could be confirmed.")

        await checkout.processPayment()
        checkout.flushDraft()
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertNotEqual(checkout.state, .confirmed)
        XCTAssertNil(visit.endedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Payment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CheckoutTransaction>()), 0)
        let draft = await CheckoutDraftStore(directoryURL: draftDirectory).loadDraft(for: visit.uuid)
        XCTAssertNil(draft, "The tour's jump to Review is not saved as a recovery draft.")

        // If the checkout outlives the tour it starts over, unvalidated steps discarded.
        checkout.endWalkthroughPreview()
        XCTAssertFalse(checkout.isWalkthroughPreview)
        XCTAssertEqual(checkout.currentStep, .services)
    }

    func testStepJumpsOutsideTourPreviewAreIgnored() {
        let owner = Client(firstName: "Rosa", lastName: "Diaz")
        let pet = Pet(name: "Pepper", species: .dog)
        pet.owner = owner
        context.insert(owner)
        context.insert(pet)
        let visit = Visit(pet: pet)
        context.insert(visit)

        let checkout = makeCheckout(pet: pet, visit: visit, services: [])
        checkout.showStepForWalkthrough(.review)
        XCTAssertEqual(checkout.currentStep, .services, "Real checkouts only move through advance(), which validates.")
    }

    // MARK: - Harness

    /// Walks one replay the way the app runs it. The overlay lets a tap reach
    /// the highlighted control only on steps with `allowsTargetInteraction`,
    /// so that is the only time a check-in could happen. Checkout stops make
    /// the calls CheckoutView makes, plus a stray ⌘Return on Confirm.
    private func replayTour(role: OnboardingRole, bath: Service) async throws {
        let tourContext = WalkthroughTourContext.resolve(in: context)
        XCTAssertTrue(tourContext.isExplainOnly)
        let controller = WalkthroughController()
        controller.restart(WalkthroughController.tour(for: role, context: tourContext))

        let routedClient = SampleData.tourClient(in: context)
        if let routedClient {
            XCTAssertTrue(SampleData.isSample(routedClient), "The tour only ever opens a sample client.")
        }

        var checkout: CheckoutViewModel?
        // Held until the end: checkIn runs in a Task that drops out if its
        // view model is gone, which would make a real check-in look like none.
        var detailModels: [ClientDetailViewModel] = []
        var guardSteps = 0
        while let step = controller.currentStep, guardSteps < 200 {
            guardSteps += 1

            if step.anchor == .cdCheckIn, step.allowsTargetInteraction, let routedClient {
                let detail = ClientDetailViewModel(client: routedClient, modelContext: context)
                detailModels.append(detail)
                for pet in routedClient.pets ?? [] { detail.checkIn(pet: pet) }
            }

            if step.presents == .checkout, let target = CheckoutViewModel.CheckoutFlowStep.walkthroughStep(for: step.anchor) {
                if checkout == nil, let routedClient,
                   let pet = (routedClient.pets ?? []).first(where: { $0.activeVisit != nil }),
                   let visit = pet.activeVisit {
                    checkout = makeCheckout(pet: pet, visit: visit, services: [bath])
                }
                checkout?.beginWalkthroughPreview()
                checkout?.showStepForWalkthrough(target)
                if step.anchor == .coConfirm {
                    await checkout?.processPayment()
                }
            }

            controller.advance()
        }
        XCTAssertFalse(controller.isActive, "The replay reached its end with Next alone.")
        checkout?.flushDraft()
        try await Task.sleep(for: .milliseconds(600))
        withExtendedLifetime(detailModels) {}
    }

    private func makeCheckout(pet: Pet, visit: Visit, services: [Service]) -> CheckoutViewModel {
        let checkout = CheckoutViewModel(
            pet: pet,
            visit: visit,
            draftStore: CheckoutDraftStore(directoryURL: draftDirectory),
            eventRecorder: CheckoutEventRecorder(logURL: draftDirectory.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).log"))
        )
        checkout.allServices = services
        return checkout
    }

    private struct Counts: Equatable {
        let clients: Int
        let visits: Int
        let completedVisits: Int
        let payments: Int
        let transactions: Int
    }

    private func counts() throws -> Counts {
        let fresh = ModelContext(container)
        return Counts(
            clients: try fresh.fetchCount(FetchDescriptor<Client>()),
            visits: try fresh.fetchCount(FetchDescriptor<Visit>()),
            completedVisits: try fresh.fetchCount(FetchDescriptor<Visit>(predicate: #Predicate { $0.endedAt != nil })),
            payments: try fresh.fetchCount(FetchDescriptor<Payment>()),
            transactions: try fresh.fetchCount(FetchDescriptor<CheckoutTransaction>())
        )
    }
}
