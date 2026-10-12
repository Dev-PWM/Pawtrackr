//
//  WalkthroughSetupStopsTests.swift
//  PawtrackrTests
//
//  The Academy's chapters and the stops that bracket it: the app map it
//  opens on, the Settings stop it ends on, the loyalty stops on client
//  details and in Settings, and chapter names in Spanish.
//

import XCTest
@testable import Pawtrackr

@MainActor
final class WalkthroughSetupStopsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride)
        super.tearDown()
    }

    func testTheAcademyOpensOnTheAppMapAndEndsInSettings() throws {
        let steps = WalkthroughController.tour(for: .ownerManager, context: .practice)
        let first = try XCTUnwrap(steps.first)
        XCTAssertEqual(first.id, WalkthroughStepID.first)
        XCTAssertEqual(first.anchor, .appNavigation)
        XCTAssertEqual(first.surface, .dashboard)
        XCTAssertFalse(first.allowsTargetInteraction, "Look-only: a tap on the menu moves the tour on, not the app.")

        let last = try XCTUnwrap(steps.last)
        XCTAssertEqual(last.id, WalkthroughStepID.academyHome)
        XCTAssertEqual(last.anchor, .setAbout)
        XCTAssertEqual(last.surface, .settings)
        XCTAssertEqual(SettingSection.walkthroughSection(for: last.anchor), .about, "The tour opens Settings > About for it.")
    }

    func testTheBackupStopOnlyExplainsTheExport() throws {
        let step = try XCTUnwrap(WalkthroughController.fullTour().first { $0.id == WalkthroughStepID.backups })
        XCTAssertEqual(step.anchor, .setData)
        XCTAssertEqual(SettingSection.walkthroughSection(for: step.anchor), .dataExport)
        XCTAssertFalse(step.allowsTargetInteraction, "An export reads the real salon, so the stop never runs one.")
        XCTAssertNil(step.advancesOn)
        XCTAssertFalse(SecureStoreSnapshotExporter.isUserFacingExportEnabled, "If encrypted backups ship, teach them here.")
    }

    func testTheLoyaltyAnchorIsNoLongerOnTheOnboardingCover() throws {
        let onboarding = try source("Pawtrackr/Features/Onboarding/OnboardingView.swift")
        XCTAssertFalse(onboarding.contains("walkthroughTarget(.loyaltySimulator)"), "No tour overlay exists on the onboarding cover.")
        XCTAssertFalse(onboarding.contains("tryItTourAnchor"))
        let loyalty = try source("Pawtrackr/Features/Loyalty/LoyaltyManagementView.swift")
        XCTAssertTrue(loyalty.contains(".walkthroughTarget(.loyaltySimulator)"))
    }

    /// Settings > Loyalty: a hands-on stop on the preview's Try it box. The
    /// preview writes nothing, and playing with it shows Next instead of
    /// moving on, so the new points stay on screen.
    func testTheLoyaltyExplanationNeedsNoManualInput() throws {
        for role in OnboardingRole.allCases {
            let ids = WalkthroughController.tour(for: role, context: .practice).map(\.id)
            let index = try XCTUnwrap(ids.firstIndex(of: WalkthroughStepID.loyaltyPoints), "\(role)")
            XCTAssertEqual(ids[index + 1], WalkthroughStepID.backups, "Settings in sidebar order: Loyalty, then Data Export. \(role)")
        }

        let step = try XCTUnwrap(WalkthroughController.fullTour().first { $0.id == WalkthroughStepID.loyaltyPoints })
        XCTAssertEqual(step.anchor, .loyaltySimulator)
        XCTAssertEqual(step.surface, .settings)
        XCTAssertEqual(SettingSection.walkthroughSection(for: step.anchor), .loyalty)
        XCTAssertEqual(step.lesson, .businessInsights)
        XCTAssertTrue(step.allowsTargetInteraction, "The slider, tier and rebook switch must be usable.")
        XCTAssertFalse(step.requiresTargetAction)
        XCTAssertNil(step.advancesOn, "The first drag would move the tour on before the points could be read.")

        let controller = WalkthroughController()
        controller.targetWatchdogDelay = nil
        controller.missionPatience = nil
        controller.start(WalkthroughController.tour(for: .frontDeskGroomer, context: .practice), at: step.id)
        XCTAssertTrue(controller.currentStepShowsNext, "The explanation needs no input.")
        controller.releaseActionRequirement(reason: "the loyalty preview changed")
        XCTAssertTrue(controller.currentStepShowsNext)
        XCTAssertEqual(controller.currentStep?.id, step.id, "Playing with the preview never skips ahead.")
        controller.skip()


    }

    func testLoyaltyCopyNamesTheRealScreens() throws {
        UserDefaults.standard.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        var steps = Dictionary(uniqueKeysWithValues: WalkthroughController.fullTour().map { ($0.id, $0) })
        let client = try XCTUnwrap(steps[WalkthroughStepID.clientLoyalty])
        XCTAssertTrue(client.directive.contains("Loyalty & Rewards"), client.directive)
        let rewardTip = try XCTUnwrap(client.coachTip)
        XCTAssertTrue(rewardTip.contains("Payment step"), "Names where the reward is chosen.")
        XCTAssertTrue(rewardTip.contains("choose a reward"), "Says how points are spent.")
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.loyaltyPoints]?.coachTip).contains("How points are calculated"))

        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        steps = Dictionary(uniqueKeysWithValues: WalkthroughController.fullTour().map { ($0.id, $0) })
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.clientLoyalty]).directive.contains("Lealtad y recompensas"))
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.loyaltyPoints]?.coachTip).contains("Cómo se calculan los puntos"))
    }

    func testClientLoyaltyStopsAreInBothTours() throws {
        for role in OnboardingRole.allCases {
            let ids = WalkthroughController.tour(for: role, context: .practice).map(\.id)
            XCTAssertTrue(ids.contains(WalkthroughStepID.clientLoyalty), "\(role)")
        }
        // Client details only open the sample client, so without one the
        // loyalty card stop goes with the other client-detail stops.
        let noSample = WalkthroughTourContext(hasSampleClient: false, hasRealClients: true)
        XCTAssertFalse(WalkthroughController.tour(for: .ownerManager, context: noSample).contains { $0.id == WalkthroughStepID.clientLoyalty })
    }

    func testChapterNamesAreTranslated() {
        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        XCTAssertEqual(
            WalkthroughLesson.allCases.map(\.title),
            ["Panel", "Directorio de clientes", "Perfiles y mascotas", "Visitas y pagos", "Estadísticas y respaldos"]
        )
        UserDefaults.standard.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        XCTAssertEqual(
            WalkthroughLesson.allCases.map(\.title),
            ["Dashboard", "Client Directory", "Profiles & Pets", "Visits & Payments", "Insights & Backups"]
        )
    }

    func testMissionCopyInSpanishNamesTheRealButtons() throws {
        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        let steps = Dictionary(uniqueKeysWithValues: WalkthroughController.fullTour().map { ($0.id, $0) })
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.checkIn]?.action).contains("Registrar entrada"))
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.checkOut]?.action).contains("Registrar salida"))
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.clientsTab]?.action).contains("Clientes"))
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.insightsTab]?.action).contains("Estadísticas"))
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
