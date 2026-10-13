import XCTest
import SwiftData
import SwiftUI
@testable import Pawtrackr

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        resetAppSettingsDefaults()

        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        resetAppSettingsDefaults()
        unsetenv("PAWTRACKR_UI_TESTING")
        unsetenv("PAWTRACKR_UI_START_WALKTHROUGH")
        try super.tearDownWithError()
    }

    func testBuildingTheViewModelDoesNotWriteTheDraft() {
        // SwiftUI builds a new OnboardingViewModel on every RootView render.
        // An init that wrote UserDefaults re-invalidated @AppStorage-backed
        // views and looped forever on a blank onboarding screen.
        let draftKey = "com.pawtrackr.onboarding.draft"
        UserDefaults.standard.removeObject(forKey: draftKey)
        defer { UserDefaults.standard.removeObject(forKey: draftKey) }

        _ = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        XCTAssertNil(UserDefaults.standard.object(forKey: draftKey))

        let saved: [String: Any] = ["name": "Bark & Bathe", "currency": "€"]
        UserDefaults.standard.set(saved, forKey: draftKey)
        let restored = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        XCTAssertEqual(restored.name, "Bark & Bathe")
        XCTAssertEqual(
            UserDefaults.standard.dictionary(forKey: draftKey) as NSDictionary?,
            saved as NSDictionary,
            "Restoring a draft must not rewrite it."
        )

        restored.name = "Bark & Bathe Co."
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: draftKey)?["name"] as? String, "Bark & Bathe Co.",
                       "Edits after init still save.")
    }

    func testResumingLegacyDraftPreservesChoicesAndDropsRole() {
        // OnboardingView builds the view model with nil settings, then binds
        // the real AppSettings in .task. Those still hold the registered
        // defaults (onboarding writes them only in finish), so binding used
        // to reset a resumed Front Desk user to the owner tour.
        let draftKey = "com.pawtrackr.onboarding.draft"
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.onboardingRole)
        UserDefaults.standard.set([
            "name": "Bark & Bathe",
            "selectedRole": OnboardingRole.frontDeskGroomer.rawValue,
            "currency": "€",
            "lockOnBackgroundEnabled": false,
            "autoLockAfterInactivityEnabled": true
        ] as [String: Any], forKey: draftKey)
        defer {
            UserDefaults.standard.removeObject(forKey: draftKey)
            UserDefaults.standard.removeObject(forKey: AppSettingsKeys.onboardingRole)
        }

        let viewModel = OnboardingViewModel(modelContext: nil, appSettings: nil)

        let settings = AppSettings()
        XCTAssertEqual(settings.onboardingRole, .ownerManager, "Precondition: settings still hold the default role.")
        viewModel.bindIfNeeded(modelContext: context, appSettings: settings)

        XCTAssertEqual(viewModel.currentCurrency, "€")
        XCTAssertFalse(viewModel.lockOnBackgroundEnabled)
        XCTAssertTrue(viewModel.autoLockAfterInactivityEnabled)
        viewModel.name = "Bark & Bathe Updated"
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: draftKey)?["selectedRole"],
                     "New drafts no longer contain a role choice.")
    }

    func testBindingWithoutADraftStillReadsTheSettings() {
        let draftKey = "com.pawtrackr.onboarding.draft"
        UserDefaults.standard.removeObject(forKey: draftKey)
        defer {
            UserDefaults.standard.removeObject(forKey: draftKey)
            UserDefaults.standard.removeObject(forKey: AppSettingsKeys.onboardingRole)
        }

        let settings = AppSettings()
        settings.onboardingRole = .frontDeskGroomer
        settings.currencySymbol = "€"

        let viewModel = OnboardingViewModel(modelContext: nil, appSettings: nil)
        viewModel.bindIfNeeded(modelContext: context, appSettings: settings)

        XCTAssertEqual(viewModel.currentCurrency, "€")
    }

    func testRegionalStepAllowsBlankEmailButRejectsInvalidEmail() {
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        viewModel.currentStep = .regional

        viewModel.email = ""
        XCTAssertTrue(viewModel.canGoNext)

        viewModel.email = "invalid-email"
        XCTAssertFalse(viewModel.canGoNext)
        XCTAssertEqual(viewModel.regionalValidationMessage, "Enter a valid email address (e.g., hello@business.com).")

        viewModel.email = "owner@example.com"
        XCTAssertTrue(viewModel.canGoNext)
        XCTAssertNil(viewModel.regionalValidationMessage)
    }

    func testSecurityStepRequiresFourDigitNumericMatch() {
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        viewModel.currentStep = .security

        viewModel.pin = "12"
        viewModel.confirmPin = "12"
        XCTAssertFalse(viewModel.canGoNext)

        viewModel.pin = "12ab"
        viewModel.confirmPin = "12ab"
        XCTAssertFalse(viewModel.canGoNext)
        XCTAssertEqual(viewModel.securityValidationMessage, "PIN must use numbers only.")

        viewModel.pin = "4826"
        viewModel.confirmPin = "4827"
        XCTAssertFalse(viewModel.canGoNext)
        XCTAssertEqual(viewModel.securityValidationMessage, "PINs do not match.")

        viewModel.confirmPin = "4826"
        XCTAssertTrue(viewModel.canGoNext)
        XCTAssertNil(viewModel.securityValidationMessage)
    }

    func testFinishPersistsBusinessConfigAndSettings() async throws {
        let settings = AppSettings()
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: settings)

        viewModel.name = "Northside Grooming"
        viewModel.email = "hello@northside.example"
        viewModel.phone = "3125550188"
        viewModel.address = "123 Paw Street"
        viewModel.currencySymbol = "€"
        viewModel.lockOnBackgroundEnabled = false
        viewModel.autoLockAfterInactivityEnabled = true
        viewModel.biometricsEnabled = false
        viewModel.pin = "4826"
        viewModel.confirmPin = "4826"

        var completed = false
        let task = await viewModel.finish(seedSampleData: false) {
            completed = true
        }
        _ = await task?.result

        XCTAssertTrue(completed)
        XCTAssertNil(viewModel.saveError)
        XCTAssertEqual(settings.businessName, "Northside Grooming")
        XCTAssertEqual(settings.currencySymbol, "€")
        XCTAssertFalse(settings.autoLockOnBackground)
        XCTAssertTrue(settings.autoLockAfterInactivity)
        XCTAssertTrue(settings.validatePIN("4826"))

        let configs = try context.fetch(FetchDescriptor<BusinessConfig>())
        XCTAssertEqual(configs.first?.name, "Northside Grooming")
        XCTAssertEqual(configs.first?.email, "hello@northside.example")
        XCTAssertEqual(configs.first?.phone, "3125550188")
        XCTAssertEqual(configs.first?.address, "123 Paw Street")
        XCTAssertEqual(configs.first?.isSetupComplete, true)
    }

    func testFreeTextFieldsClampBeforeDraftAndFinishPersistence() async throws {
        let settings = AppSettings()
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: settings)

        viewModel.name = String(repeating: "Northside Grooming ", count: 20)
        viewModel.email = String(repeating: "owner", count: 80) + "@example.com"
        viewModel.phone = String(repeating: "5", count: 80)
        viewModel.address = String(repeating: "123 Very Long Street ", count: 30)
        viewModel.pin = "4826"
        viewModel.confirmPin = "4826"

        XCTAssertLessThanOrEqual(viewModel.name.count, TextInputLimits.name)
        XCTAssertLessThanOrEqual(viewModel.email.count, TextInputLimits.email)
        XCTAssertLessThanOrEqual(viewModel.phone.count, TextInputLimits.phone)
        XCTAssertLessThanOrEqual(viewModel.address.count, TextInputLimits.address)

        viewModel.email = "owner@example.com"
        let task = await viewModel.finish(seedSampleData: false) { }
        _ = await task?.result

        XCTAssertNil(viewModel.saveError)
        XCTAssertLessThanOrEqual(settings.businessName.count, TextInputLimits.name)
        let configs = try context.fetch(FetchDescriptor<BusinessConfig>())
        let config = try XCTUnwrap(configs.first)
        XCTAssertLessThanOrEqual(config.name.count, TextInputLimits.name)
        XCTAssertLessThanOrEqual(config.email?.count ?? 0, TextInputLimits.email)
        XCTAssertLessThanOrEqual(config.phone?.count ?? 0, TextInputLimits.phone)
        XCTAssertLessThanOrEqual(config.address?.count ?? 0, TextInputLimits.address)
    }

    func testFinishWithDemoDataSeedsStarterRecords() async throws {
        let settings = AppSettings()
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: settings)

        viewModel.name = "Harbor Grooming"
        viewModel.currencySymbol = "$"
        viewModel.pin = "4826"
        viewModel.confirmPin = "4826"

        let task = await viewModel.finish(seedSampleData: true) { }
        _ = await task?.result

        XCTAssertNil(viewModel.saveError)
        XCTAssertFalse(settings.isChecklistDismissed, "Setup shows the Getting Started card.")

        // After fix #2 the demo seeder runs on a background context, so the
        // newly inserted records live on the shared store but may not be in the
        // main context's row cache yet — re-fetch with a fresh background context
        // to verify they actually persisted.
        let bgContext = ModelContext(container)
        XCTAssertGreaterThan(try bgContext.fetchCount(FetchDescriptor<Client>()), 0)
        XCTAssertGreaterThan(try bgContext.fetchCount(FetchDescriptor<Visit>()), 0)
        XCTAssertGreaterThan(try bgContext.fetchCount(FetchDescriptor<Service>()), 0)
        XCTAssertTrue(
            try bgContext.fetch(FetchDescriptor<Service>()).contains { $0.basePrice != nil },
            "Loading the samples gives unpriced services an example price."
        )
    }

    // MARK: - Navigation

    func testNextStep_ProgressesThroughAllStepsWhenValid() {
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        XCTAssertEqual(viewModel.currentStep, .welcome)

        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .businessProfile)

        // Business profile blocks until name is set.
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .businessProfile, "Should stay on businessProfile when name is empty.")

        viewModel.name = "Test Grooming"
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .regional)

        // Regional accepts blank email.
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .security)

        // Security blocks until PINs are valid and matching.
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .security)

        viewModel.pin = "1234"
        viewModel.confirmPin = "1234"
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .permissions)

        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .loyalty)

        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .warmStart)

        // Warm start is the last step — nextStep beyond it should be a no-op.
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .warmStart)
    }

    func testPreviousStep_GoesBackButStopsAtWelcome() {
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        viewModel.currentStep = .regional

        viewModel.previousStep()
        XCTAssertEqual(viewModel.currentStep, .businessProfile)

        viewModel.previousStep()
        XCTAssertEqual(viewModel.currentStep, .welcome)

        viewModel.previousStep()
        XCTAssertEqual(viewModel.currentStep, .welcome, "previousStep at welcome should be a no-op.")
    }

    func testGoToStep_OnlyPermitsBackwardsNavigation() {
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: AppSettings())
        viewModel.currentStep = .security

        viewModel.goToStep(.businessProfile)
        XCTAssertEqual(viewModel.currentStep, .businessProfile, "Backwards jump should succeed.")

        viewModel.goToStep(.permissions)
        XCTAssertEqual(viewModel.currentStep, .businessProfile, "Forward jump should be ignored.")

        viewModel.goToStep(.businessProfile)
        XCTAssertEqual(viewModel.currentStep, .businessProfile, "Same-step jump should be a no-op.")
    }

    func testPrimaryActionTitle_VariesByStep() {
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: AppSettings())

        viewModel.currentStep = .welcome
        XCTAssertEqual(viewModel.primaryActionTitle, "Get Started")

        viewModel.currentStep = .businessProfile
        XCTAssertEqual(viewModel.primaryActionTitle, "Continue")

        viewModel.currentStep = .loyalty
        XCTAssertEqual(viewModel.primaryActionTitle, "Review Setup")

        viewModel.currentStep = .permissions
        XCTAssertEqual(viewModel.primaryActionTitle, "Continue")

        viewModel.currentStep = .warmStart
        XCTAssertEqual(viewModel.primaryActionTitle, "Continue")
    }

    func testFullWalkthroughTeachesCompleteNewUserCurriculum() throws {
        let steps = WalkthroughController.fullTour()
        let lessons = Set(steps.map(\.lesson))

        XCTAssertGreaterThanOrEqual(steps.count, 24)
        XCTAssertEqual(lessons, Set(WalkthroughLesson.allCases))
        XCTAssertEqual(
            steps.filter { $0.presents == .newClient }.map(\.anchor),
            [.ncOwner, .ncPets, .ncSave],
            "The create-client lesson should open one coherent New Client mini-flow."
        )
        XCTAssertTrue(
            steps.filter { $0.presents == .newClient }.allSatisfy(\.allowsTargetInteraction),
            "The New Client lesson must let the user type into the form and tap Create instead of the overlay swallowing the action."
        )
        let saveStep = try XCTUnwrap(steps.first { $0.anchor == .ncSave })
        XCTAssertTrue(saveStep.purpose.localizedCaseInsensitiveContains("Create"))
        XCTAssertFalse(saveStep.purpose.localizedCaseInsensitiveContains("without saving"))
        XCTAssertGreaterThanOrEqual(steps.compactMap(\.coachTip).count, 8)
        XCTAssertTrue(steps.contains { $0.purpose.localizedCaseInsensitiveContains("check in") })
        XCTAssertTrue(steps.contains { $0.purpose.localizedCaseInsensitiveContains("checkout") })
        XCTAssertTrue(steps.contains { $0.purpose.localizedCaseInsensitiveContains("receipt") })
        XCTAssertTrue(steps.contains { $0.purpose.localizedCaseInsensitiveContains("history") })
        XCTAssertFalse(steps.contains { $0.purpose.localizedCaseInsensitiveContains("iCloud") })
        XCTAssertTrue(steps.contains { $0.purpose.localizedCaseInsensitiveContains("practice salon") })
        XCTAssertFalse(steps.contains { $0.title.trimmed.isEmpty || $0.directive.trimmed.isEmpty || $0.purpose.trimmed.isEmpty })
    }

    func testFullWalkthroughIncludesClientProfileAndEndsAtTheAcademyHome() throws {
        let steps = WalkthroughController.fullTour()

        XCTAssertTrue(
            steps.contains { $0.title.localizedCaseInsensitiveContains("Client profile") },
            "The walkthrough should open and explain an actual client profile."
        )
        XCTAssertTrue(
            steps.contains { $0.title.localizedCaseInsensitiveContains("Emergency Contacts") },
            "Client details should teach emergency contacts because they are not obvious from the Clients list."
        )

        let finalStep = try XCTUnwrap(steps.last)
        XCTAssertEqual(finalStep.anchor, .setAbout)
        XCTAssertTrue(finalStep.directive.localizedCaseInsensitiveContains("re-run the whole Academy"))
        XCTAssertTrue(finalStep.purpose.localizedCaseInsensitiveContains("practice salon"))
    }

    func testEveryRoleGetsTheWholeAcademy() {
        let ownerAnchors = WalkthroughController.tour(for: .ownerManager, context: .practice).map(\.anchor)
        let staffAnchors = WalkthroughController.tour(for: .frontDeskGroomer, context: .practice).map(\.anchor)

        XCTAssertEqual(ownerAnchors, staffAnchors, "Front desk and owners learn the same app.")
        for anchor: WalkthroughAnchorID in [
            .appNavigation, .dashKpis, .dashQuickActions, .dashNeedsAttention, .dashRecentClients,
            .clientSearch, .clientBell, .clientFilters, .clientSort, .clientList,
            .cdOwner, .cdEmergency, .cdLoyalty, .cdAddPet, .cdCheckIn, .cdCheckOut,
            .coServices, .coPayment, .coConfirm, .cdHistory, .cdVisitRow,
            .insRevenue, .insServices, .insPaymentMix, .setData, .setAbout
        ] {
            XCTAssertTrue(ownerAnchors.contains(anchor), "\(anchor)")
        }
        let insights = WalkthroughController.steps(for: .businessInsights, role: .frontDeskGroomer, context: .practice).map(\.anchor)
        XCTAssertEqual(insights, [.insights, .insRevenue, .insServices, .insPaymentMix, .loyaltySimulator, .setData, .setAbout])
    }

    func testFullWalkthroughTeachesCheckoutAndHistoryAsDedicatedProcess() throws {
        let steps = WalkthroughController.fullTour()
        let anchors = steps.map(\.anchor)

        XCTAssertTrue(anchors.contains(.cdCheckIn), "Check In should have its own stop, not only a grouped pet-actions explanation.")
        XCTAssertTrue(anchors.contains(.cdCheckOut), "Check Out should have its own stop so the user understands when checkout becomes available.")
        XCTAssertTrue(anchors.contains(.cdLoyalty), "Client details should show where checkout-earned loyalty points appear.")
        XCTAssertTrue(anchors.contains(.coServices), "The tour should open checkout and explain the Services step in the real checkout UI.")
        XCTAssertTrue(anchors.contains(.coPayment), "The tour should open checkout and explain the Payment step in the real checkout UI.")
        XCTAssertTrue(anchors.contains(.coConfirm), "The tour should explain the final Confirm & Pay action in the real checkout UI.")
        XCTAssertTrue(anchors.contains(.cdHistory), "Recent History should remain part of the client-detail chapter.")
        XCTAssertTrue(anchors.contains(.cdVisitRow), "Opening a saved visit shows the whole ticket.")

        let checkInStep = try XCTUnwrap(steps.first { $0.anchor == .cdCheckIn })
        XCTAssertTrue(checkInStep.allowsTargetInteraction)
        XCTAssertTrue(checkInStep.requiresTargetAction)

        let checkOutStep = try XCTUnwrap(steps.first { $0.anchor == .cdCheckOut })
        XCTAssertTrue(checkOutStep.allowsTargetInteraction)
        XCTAssertTrue(checkOutStep.requiresTargetAction)
        XCTAssertTrue(checkOutStep.purpose.localizedCaseInsensitiveContains("services"))
        XCTAssertTrue(checkOutStep.purpose.localizedCaseInsensitiveContains("payment"))

        let checkoutSteps = steps.filter { $0.presents == .checkout }
        XCTAssertEqual(checkoutSteps.map(\.anchor), [.coServices, .coPayment, .coConfirm])
        XCTAssertTrue(checkoutSteps.allSatisfy { $0.lesson == .checkoutAndMoney })
        XCTAssertTrue(checkoutSteps[0].purpose.localizedCaseInsensitiveContains("subtotal"))
        XCTAssertTrue(checkoutSteps[1].purpose.localizedCaseInsensitiveContains("amount"))
        XCTAssertTrue(checkoutSteps[1].purpose.localizedCaseInsensitiveContains("reference"))
        XCTAssertTrue(checkoutSteps[2].purpose.localizedCaseInsensitiveContains("insights"))
        XCTAssertTrue(checkoutSteps[2].purpose.localizedCaseInsensitiveContains("nothing is charged"))
        XCTAssertTrue(checkoutSteps[2].coachTip?.localizedCaseInsensitiveContains("loyalty points") == true)

        let visitStep = try XCTUnwrap(steps.first { $0.anchor == .cdVisitRow })
        XCTAssertTrue(visitStep.directive.localizedCaseInsensitiveContains("Paid"))
        XCTAssertEqual(visitStep.advancesOn, .visitOpened)
    }

    func testSpanishWalkthroughCopyDoesNotLeaveWalkthroughInEnglish() {
        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)

        let leakedCopy = WalkthroughController.fullTour().flatMap { step in
            [step.title, step.directive, step.purpose, step.coachTip].compactMap(\.self)
        }.filter { $0.localizedCaseInsensitiveContains("walkthrough") }

        XCTAssertTrue(leakedCopy.isEmpty, "Spanish walkthrough copy should use recorrido instead of leaving walkthrough in English: \(leakedCopy)")
    }

    func testFullWalkthroughCopyStaysShortAndPlainInEnglish() {
        UserDefaults.standard.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)

        assertWalkthroughCopyIsShortAndPlain(WalkthroughController.fullTour())
    }

    func testFullWalkthroughCopyStaysShortAndPlainInSpanish() {
        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)

        assertWalkthroughCopyIsShortAndPlain(WalkthroughController.fullTour())
    }

    func testAddPetWalkthroughWaitsForLiveTargetInsteadOfMacToolbarFallback() {
        XCTAssertEqual(
            WalkthroughController.addPetSpotlightFallback,
            .none,
            "Add Pet should highlight the visible paw Add Pet control; a top-trailing fallback can point at empty toolbar space on macOS."
        )
    }

    func testWalkthroughReplayRestartsFromFirstStepEvenWhenAlreadyActive() throws {
        let controller = WalkthroughController()
        let steps = WalkthroughController.fullTour()
        controller.start(steps)
        controller.advance()
        controller.advance()

        XCTAssertGreaterThan(controller.currentIndex, 0)

        controller.restart(WalkthroughController.fullTour())

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.currentStep?.anchor, .appNavigation)
    }

    func testWalkthroughBackReturnsToPreviousClientDetailActionStep() throws {
        let controller = WalkthroughController()
        let steps = WalkthroughController.fullTour()
        let checkOutIndex = try XCTUnwrap(steps.firstIndex { $0.anchor == .cdCheckOut })
        controller.start(steps)

        while controller.currentIndex < checkOutIndex {
            controller.advance()
        }

        XCTAssertEqual(controller.currentStep?.anchor, .cdCheckOut)
        XCTAssertTrue(controller.canGoBack)

        controller.goBack()

        XCTAssertEqual(controller.currentStep?.anchor, .cdCheckIn)
        XCTAssertTrue(controller.isActive)
    }

    func testWalkthroughCompletesNewClientChapterAfterUserCreatesClient() throws {
        let controller = WalkthroughController()
        let steps = WalkthroughController.fullTour()
        let newClientIndex = try XCTUnwrap(steps.firstIndex { $0.presents == .newClient })
        controller.start(steps)

        while controller.currentIndex < newClientIndex {
            controller.advance()
        }

        XCTAssertEqual(controller.currentStep?.anchor, .ncOwner)
        XCTAssertEqual(controller.currentStep?.presents, .newClient)

        controller.completePresentation(.newClient)

        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.currentStep?.presents)
        XCTAssertEqual(controller.currentStep?.anchor, .clientList)
        controller.observe(.clientOpened)
        XCTAssertEqual(controller.currentStep?.anchor, .cdOwner)
        XCTAssertEqual(controller.currentStep?.route, .demoClientDetail)
    }

    func testWalkthroughCompletionKeepsCreatedClientPreferenceForDetailsChapter() throws {
        let controller = WalkthroughController()
        let client = Client(firstName: "Tour", lastName: "Client")
        context.insert(client)
        try context.save()

        let steps = WalkthroughController.fullTour()
        let newClientIndex = try XCTUnwrap(steps.firstIndex { $0.presents == .newClient })
        controller.start(steps)

        while controller.currentIndex < newClientIndex {
            controller.advance()
        }

        controller.focusClientDetail(client.persistentModelID)
        controller.completePresentation(.newClient)

        XCTAssertEqual(controller.currentStep?.anchor, .clientList)
        controller.observe(.clientOpened)
        XCTAssertEqual(controller.currentStep?.anchor, .cdOwner)
        XCTAssertEqual(controller.preferredClientDetailID, client.persistentModelID)
    }

    func testUITestWalkthroughLaunchFlagIsNarrowAndExplicit() {
        unsetenv("PAWTRACKR_UI_TESTING")
        unsetenv("PAWTRACKR_UI_START_WALKTHROUGH")
        XCTAssertFalse(AppRuntime.shouldStartWalkthroughForUITesting)

        setenv("PAWTRACKR_UI_TESTING", "1", 1)
        setenv("PAWTRACKR_UI_START_WALKTHROUGH", "0", 1)
        XCTAssertFalse(AppRuntime.shouldStartWalkthroughForUITesting)

        setenv("PAWTRACKR_UI_START_WALKTHROUGH", "1", 1)
        XCTAssertTrue(AppRuntime.shouldStartWalkthroughForUITesting)

        unsetenv("PAWTRACKR_UI_TESTING")
        setenv("PAWTRACKR_UI_START_WALKTHROUGH", "1", 1)
        XCTAssertFalse(AppRuntime.shouldStartWalkthroughForUITesting)
    }


    func testWalkthroughTargetFrameRejectsOffscreenAndTinyRects() {
        let container = CGSize(width: 1024, height: 768)
        let insets = EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)

        XCTAssertNil(WalkthroughTargetFrame.validated(CGRect(x: -800, y: -200, width: 40, height: 40), in: container, safeAreaInsets: insets))
        XCTAssertNil(WalkthroughTargetFrame.validated(CGRect(x: 200, y: 200, width: 0.5, height: 24), in: container, safeAreaInsets: insets))

        // Also reject non-finite values
        XCTAssertNil(WalkthroughTargetFrame.validated(CGRect(x: CGFloat.nan, y: 0, width: 40, height: 40), in: container, safeAreaInsets: insets))
        XCTAssertNil(WalkthroughTargetFrame.validated(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40), in: container, safeAreaInsets: insets))

        // WalkthroughTargetFrame.validated should clamp rects to safe bounds with an 8pt buffer:
        // maxX: 1024 - 8 = 1016
        // maxY: (768 - 20 bottom inset) - 8 = 740
        let visible = WalkthroughTargetFrame.validated(CGRect(x: 980, y: 720, width: 80, height: 80), in: container, safeAreaInsets: insets)
        XCTAssertEqual(visible?.maxX, 1016)
        XCTAssertEqual(visible?.maxY, 740)
    }

    /// Settings > About on the Mac: the detail column reports the sidebar's
    /// width as a leading inset although it already starts beside the
    /// sidebar. The Academy card's spotlight used to lose its left part to it.
    /// Oversized sections must leave enough room to read the guide on every phone.
    func testCompactPhoneOversizedTargetUsesReadableFallback() {
        let step = WalkthroughStep(id: "phone-layout", anchor: .setData, title: "Export your data",
                                   directive: "Export clients and visits.", purpose: "Keep a copy.")
        for size in [CGSize(width: 375, height: 667), CGSize(width: 390, height: 844),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            let insets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
            let result = WalkthroughOverlayLayout.layout(step: step,
                targetRect: CGRect(x: 16, y: 150, width: size.width - 32, height: size.height - 190),
                containerSize: size, safeAreaInsets: insets, compactPhone: true)
            XCTAssertEqual(result.placement, .center)
            XCTAssertNil(result.spotlight)
            XCTAssertGreaterThanOrEqual(result.cardMaxHeight, 280)
            XCTAssertLessThanOrEqual(result.cardWidth, 360)
            XCTAssertGreaterThanOrEqual(result.bubbleFrame.minY, insets.top + 8)
            XCTAssertLessThanOrEqual(result.bubbleFrame.maxY, size.height - insets.bottom - 8)
        }
    }

    func testCompactPhoneBottomTargetKeepsSpotlightAndControlsSeparate() throws {
        let step = WalkthroughStep(id: "phone-tab", anchor: .insights, title: "Open Insights",
                                   directive: "Tap Insights.", purpose: "Review your salon.")
        let size = CGSize(width: 440, height: 956)
        let result = WalkthroughOverlayLayout.layout(step: step,
            targetRect: CGRect(x: 220, y: 850, width: 100, height: 48), containerSize: size,
            safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), compactPhone: true)
        let spotlight = try XCTUnwrap(result.spotlight)
        XCTAssertEqual(result.placement, .above)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertEqual(result.cardWidth, 360)
    }

    func testSplitViewSidebarInsetDoesNotClipTheSpotlight() throws {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .setAbout,
            title: "Your Academy home",
            directive: "Continue, replay a chapter or re-run the whole Academy from here.",
            purpose: "Train new staff any time."
        )
        let container = CGSize(width: 1_817, height: 1_150)
        let insets = EdgeInsets(top: 52, leading: 183, bottom: 0, trailing: 0)
        let card = CGRect(x: 30, y: 110, width: 914, height: 200)

        XCTAssertEqual(WalkthroughTargetFrame.validated(card, in: container, safeAreaInsets: insets), card)

        let result = WalkthroughOverlayLayout.layout(step: step, targetRect: card, containerSize: container, safeAreaInsets: insets)
        let spotlight = try XCTUnwrap(result.spotlight)
        XCTAssertEqual(spotlight, card.insetBy(dx: -10, dy: -10), "The spotlight frames the whole card.")
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
    }

    func testWalkthroughInteractiveTargetBubbleDoesNotOverlapIPadCheckoutTarget() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .cdCheckOut,
            title: "Check Out",
            directive: "Tap the highlighted button.",
            purpose: "Finish the visit.",
            allowsTargetInteraction: true,
            requiresTargetAction: true
        )
        let container = CGSize(width: 834, height: 1_194)
        let target = CGRect(x: 328, y: 424, width: 252, height: 78)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertNotEqual(result.placement, .center)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight), "Interactive checkout bubble must not cover the tappable target.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughLayoutShrinksInsteadOfClampingBubbleOverTarget() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .cdCheckOut,
            title: "Check Out",
            directive: "Tap the highlighted button.",
            purpose: "Finish the visit.",
            allowsTargetInteraction: true,
            requiresTargetAction: true
        )
        let container = CGSize(width: 834, height: 600)
        let target = CGRect(x: 260, y: 200, width: 300, height: 260)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertNotEqual(result.placement, .center)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight), "Clamping a bubble into safe bounds must not push it back over an interactive target.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughRightSideCheckoutTargetUsesLeadingBubbleOnIPadLandscape() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .cdCheckOut,
            title: "Check Out",
            directive: "Tap the highlighted button.",
            purpose: "Finish the visit.",
            allowsTargetInteraction: true,
            requiresTargetAction: true
        )
        let container = CGSize(width: 1_194, height: 834)
        let target = CGRect(x: 670, y: 406, width: 252, height: 88)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertEqual(result.placement, .leading)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight), "Right-side iPad actions need a leading bubble so the highlighted button remains tappable.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughRightSideCheckoutTargetUsesLeadingBubbleInShortDetailHost() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .cdCheckOut,
            title: "Check Out",
            directive: "Tap the highlighted button.",
            purpose: "Finish the visit.",
            allowsTargetInteraction: true,
            requiresTargetAction: true
        )
        let container = CGSize(width: 834, height: 600)
        let target = CGRect(x: 430, y: 396, width: 252, height: 88)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertEqual(result.placement, .leading)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight), "A short iPad detail host should still place the bubble beside a right-side action instead of clamping it over the target.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    /// The card hugs its copy, so a side slot that had to move up to fit on
    /// screen puts the card at its bottom, next to the target, with the
    /// arrow on the target. A slot level with the target keeps both on top.
    func testSideBubbleStaysBesideATargetNearTheBottom() throws {
        let step = WalkthroughStep(id: "layout", anchor: .cdHistory, title: "History", directive: "Look here.", purpose: "Past visits.")
        let container = CGSize(width: 1_194, height: 834)
        let insets = EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)

        let low = WalkthroughOverlayLayout.layout(step: step, targetRect: CGRect(x: 800, y: 720, width: 300, height: 60), containerSize: container, safeAreaInsets: insets)
        let lowSpotlight = try XCTUnwrap(low.spotlight)
        XCTAssertEqual(low.placement, .leading)
        XCTAssertLessThan(low.bubbleFrame.minY, lowSpotlight.minY - 8, "The slot moved up to fit.")
        XCTAssertTrue(low.hugsBottom)
        XCTAssertEqual(low.bubbleFrame.maxY - low.arrowOffset - 11, lowSpotlight.midY, accuracy: 0.5, "The arrow points at the target.")

        let high = WalkthroughOverlayLayout.layout(step: step, targetRect: CGRect(x: 800, y: 100, width: 300, height: 60), containerSize: container, safeAreaInsets: insets)
        XCTAssertEqual(high.placement, .leading)
        XCTAssertFalse(high.hugsBottom)
        XCTAssertEqual(high.arrowOffset, 16)
    }

    func testWalkthroughBubbleStaysInBoundsForIPadLandscapePetHistoryTarget() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .cdPetHistory,
            title: "Pet History",
            directive: "Open the pet timeline.",
            purpose: "Review past visits."
        )
        let container = CGSize(width: 1_194, height: 834)
        let target = CGRect(x: 834, y: 356, width: 270, height: 76)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertNotEqual(result.placement, .center)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughCompactTabBarBubbleAppearsAboveTarget() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .dashboard,
            title: "Dashboard",
            directive: "Start here.",
            purpose: "Daily overview."
        )
        let container = CGSize(width: 393, height: 852)
        let tabTarget = CGRect(x: 20, y: 766, width: 58, height: 44)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: tabTarget,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertEqual(result.placement, .above)
        XCTAssertLessThanOrEqual(result.bubbleFrame.maxY, spotlight.minY)
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughMacSettingsBubbleIsInBoundsAndOffTarget() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .setBusiness,
            title: "Business Settings",
            directive: "Check your shop profile.",
            purpose: "These fields power receipts."
        )
        let container = CGSize(width: 1_024, height: 768)
        let target = CGRect(x: 44, y: 172, width: 560, height: 150)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 0, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertNotEqual(result.placement, .center)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertGreaterThanOrEqual(result.cardMaxHeight, 250, "A wide settings card must not force the bubble into a strip too short for its copy.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughMacWideDashboardTodaySectionKeepsGuideReadable() {
        // Step 2/38 regression (macOS, wide window): the full-width "Today" KPI
        // section used to reject the trailing bubble (its x was capped back inside
        // the spotlight), then fall back to a cramped strip above the section —
        // clipping the copy down to a bare Back / Skip / Next bar under the toolbar.
        let step = WalkthroughStep(
            id: "dash.kpis",
            anchor: .dashKpis,
            title: "Today at a glance",
            directive: "Read your live day before opening any list.",
            purpose: "In Progress, Completed, and Revenue update as you work."
        )
        let container = CGSize(width: 1_470, height: 860)
        let target = CGRect(x: 285, y: 145, width: 650, height: 160)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertNotEqual(result.placement, .center, "There is ample anchored room around the Today section.")
        XCTAssertGreaterThanOrEqual(result.cardMaxHeight, 250, "Step copy must stay readable beside a wide dashboard section.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughMacFullscreenSettingsSectionKeepsGuideReadable() {
        // Steps 33–38 regression (macOS, fullscreen): wide Settings detail cards
        // (Business, Security, About) hit the same trailing-cap rejection
        // and rendered an empty bubble pinned against the window toolbar.
        let step = WalkthroughStep(
            id: "set.business",
            anchor: .setBusiness,
            title: "Business profile",
            directive: "Brand the workspace.",
            purpose: "Set your business name, currency, and logo."
        )
        let container = CGSize(width: 1_512, height: 945)
        let target = CGRect(x: 210, y: 130, width: 930, height: 115)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertNotEqual(result.placement, .center, "Fullscreen leaves trailing room next to the settings card.")
        XCTAssertGreaterThanOrEqual(result.cardMaxHeight, 250)
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughCompactRecentHistoryHeaderKeepsGuideReadable() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .cdHistory,
            title: "Recent History",
            directive: "Review what happened last time.",
            purpose: "Completed checkouts appear here."
        )
        let container = CGSize(width: 402, height: 741)
        let target = CGRect(x: 8, y: 88, width: 386, height: 56)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertEqual(result.placement, .below)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertGreaterThanOrEqual(result.cardMaxHeight, 250, "Step 24 should have enough room to show the guide copy on iPhone.")
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughMacNewClientSaveFooterTargetStaysReadableAndOffButton() {
        let step = WalkthroughStep(
            id: "layout",
            anchor: .ncSave,
            title: "Save the client",
            directive: "Create once, reuse every visit.",
            purpose: "Tap Create when this is a real client.",
            allowsTargetInteraction: true
        )
        let container = CGSize(width: 470, height: 688)
        let target = CGRect(x: 372, y: 642, width: 82, height: 30)

        let result = WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: target,
            containerSize: container,
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        )

        let spotlight = try! XCTUnwrap(result.spotlight)
        XCTAssertEqual(result.placement, .above)
        XCTAssertFalse(result.bubbleFrame.intersects(spotlight))
        XCTAssertGreaterThanOrEqual(result.cardMaxHeight, 250)
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(result.bubbleFrame))
    }

    func testWalkthroughRemembersCreatedClientForDetailsChapter() throws {
        let controller = WalkthroughController()
        let client = Client(firstName: "Tour", lastName: "Client")
        context.insert(client)
        try context.save()

        controller.focusClientDetail(client.persistentModelID)

        XCTAssertEqual(controller.preferredClientDetailID, client.persistentModelID)

        controller.restart(WalkthroughController.fullTour())

        XCTAssertNil(controller.preferredClientDetailID)
    }

    func testFinish_RejectsBlankBusinessName() async {
        let settings = AppSettings()
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: settings)
        viewModel.name = "   "
        viewModel.pin = "1234"
        viewModel.confirmPin = "1234"

        var completionFired = false
        await viewModel.finish(seedSampleData: false) { completionFired = true }

        XCTAssertFalse(completionFired)
        XCTAssertNotNil(viewModel.saveError)
    }

    func testFinish_RejectsMismatchedPINs() async {
        let settings = AppSettings()
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: settings)
        viewModel.name = "Test"
        viewModel.pin = "1111"
        viewModel.confirmPin = "2222"

        var completionFired = false
        await viewModel.finish(seedSampleData: false) { completionFired = true }

        XCTAssertFalse(completionFired)
        XCTAssertNotNil(viewModel.saveError)
    }

    func testFinish_GuardsAgainstDoubleInvocation() async {
        let settings = AppSettings()
        let viewModel = OnboardingViewModel(modelContext: context, appSettings: settings)
        viewModel.name = "Test"
        viewModel.pin = "1234"
        viewModel.confirmPin = "1234"

        // Two concurrent finishes — the second should be a no-op while the first
        // is still in flight.
        async let first = viewModel.finish(seedSampleData: false) { }
        async let second = viewModel.finish(seedSampleData: false) { }
        _ = await (first, second)

        let configs = try? context.fetch(FetchDescriptor<BusinessConfig>())
        XCTAssertEqual(configs?.count, 1, "Should never create more than one BusinessConfig.")
    }

    private func resetAppSettingsDefaults() {
        let defaults = UserDefaults.standard
        [
            AppSettingsKeys.isLockEnabled,
            AppSettingsKeys.isBiometricLockEnabled,
            AppSettingsKeys.legacyAppPIN,
            AppSettingsKeys.lastPINChangeDate,
            AppSettingsKeys.autoLockOnBackground,
            AppSettingsKeys.autoLockAfterInactivity,
            AppSettingsKeys.businessName,
            AppSettingsKeys.currencySymbol,
            AppSettingsKeys.isChecklistDismissed,
            AppSettingsKeys.hasSeenAppTour,
            AppSettingsKeys.appLanguageOverride
        ].forEach { key in
            defaults.removeObject(forKey: key)
        }
        // PIN now lives in the Keychain; clear it explicitly so tests start fresh.
        KeychainStorage.remove(forKey: AppSettingsKeys.appPINKeychainAccount)
    }

    private func assertWalkthroughCopyIsShortAndPlain(_ steps: [WalkthroughStep], file: StaticString = #filePath, line: UInt = #line) {
        for step in steps {
            XCTAssertLessThanOrEqual(step.directive.count, 86, "Directive is too long for \(step.anchor): \(step.directive)", file: file, line: line)
            XCTAssertLessThanOrEqual(step.purpose.count, 190, "Purpose is too long for \(step.anchor): \(step.purpose)", file: file, line: line)
            if let coachTip = step.coachTip {
                XCTAssertLessThanOrEqual(coachTip.count, 150, "Coach tip is too long for \(step.anchor): \(coachTip)", file: file, line: line)
            }

            for text in [step.directive, step.purpose] + [step.coachTip].compactMap(\.self) {
                XCTAssertFalse(text.contains(";"), "Use short sentences instead of semicolons for \(step.anchor): \(text)", file: file, line: line)
                XCTAssertFalse(text.contains(" — "), "Use short sentences instead of long dash clauses for \(step.anchor): \(text)", file: file, line: line)
            }
        }
    }
}
