import XCTest
import SwiftData
@testable import Pawtrackr

/// The Academy: stable step IDs, one screen-by-screen order for every role,
/// stops that wait for the user (a tap on the highlight or a real mission)
/// and never dead-end, chapter wins, saved progress, and anchors attached
/// where the overlay that draws them can see them.
@MainActor
final class WalkthroughTourTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "WalkthroughTourTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Contexts

    /// Every combination the tour builder can be handed.
    private static var contextMatrix: [WalkthroughTourContext] {
        var contexts: [WalkthroughTourContext] = []
        for hasSampleClient in [true, false] {
            for hasRealClients in [false, true] {
                for (hasPet, hasVisit) in [(true, true), (true, false), (false, false)] {
                    for isPINSet in [false, true] {
                        for filled in [false, true] {
                            contexts.append(WalkthroughTourContext(
                                hasSampleClient: hasSampleClient,
                                hasRealClients: hasRealClients,
                                sampleClientHasPet: hasPet,
                                hasActiveSampleVisit: hasVisit,
                                isPINSet: isPINSet,
                                isBusinessProfileFilled: filled
                            ))
                        }
                    }
                }
            }
        }
        return contexts
    }

    private func lessonSequence(_ steps: [WalkthroughStep]) -> [WalkthroughLesson] {
        var sequence: [WalkthroughLesson] = []
        for step in steps where sequence.last != step.lesson {
            sequence.append(step.lesson)
        }
        return sequence
    }

    private func makeController() -> WalkthroughController {
        let controller = WalkthroughController()
        controller.targetWatchdogDelay = nil
        controller.missionPatience = nil
        return controller
    }

    private var practiceTour: [WalkthroughStep] {
        WalkthroughController.tour(for: .frontDeskGroomer, context: .practice)
    }

    func testSidebarOnlyAppearsForNavigationLessons() {
        for step in practiceTour {
            let navigationAnchors: Set<WalkthroughAnchorID> = [.appNavigation, .dashboard, .clients, .insights, .settings]
            XCTAssertEqual(step.showsNavigation, navigationAnchors.contains(step.anchor))
        }
    }

    // MARK: - Stable IDs and chapters

    func testEveryStepHasAStableUniqueID() {
        let ids = WalkthroughController.fullTour().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Step IDs must be unique: \(ids)")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertEqual(id, id.lowercased(), id)
            XCTAssertFalse(id.contains(" "), id)
        }
        // Saved progress refers to these. Renaming one loses users' place.
        for id in [WalkthroughStepID.first, "dash.kpis", "nav.clients", "clients.sort", "nc.save", "cd.checkin", "cd.checkout", "co.confirm", "set.about"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    func testStepIDsDoNotDependOnLanguageOrContext() {
        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        let spanish = WalkthroughController.tour(for: .ownerManager, context: .practice).map(\.id)
        UserDefaults.standard.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        let english = WalkthroughController.tour(for: .ownerManager, context: .practice).map(\.id)
        XCTAssertEqual(spanish, english)

        let explainOnly = WalkthroughTourContext(hasSampleClient: true, hasRealClients: true, isPINSet: true, isBusinessProfileFilled: true)
        XCTAssertEqual(WalkthroughController.tour(for: .ownerManager, context: explainOnly).map(\.id), english)
    }

    func testCatalogKeepsEachChapterTogetherInChapterOrder() {
        XCTAssertEqual(lessonSequence(WalkthroughController.fullTour()), WalkthroughLesson.allCases)
        XCTAssertEqual(WalkthroughLesson.allCases, [.dailyWorkflow, .clientRecords, .clientProfiles, .checkoutAndMoney, .businessInsights])
    }

    // MARK: - Order

    func testEveryRoleTakesTheSameAcademyInScreenOrder() {
        let owner = WalkthroughController.tour(for: .ownerManager, context: .practice)
        let frontDesk = practiceTour

        XCTAssertEqual(owner.map(\.id), frontDesk.map(\.id), "The role changes tips, never the stops.")
        XCTAssertEqual(lessonSequence(owner), WalkthroughLesson.allCases)
        for role in OnboardingRole.allCases {
            XCTAssertEqual(role.tourLessonOrder, WalkthroughLesson.allCases)
        }

        let ids = owner.map(\.id)
        let index = { (id: String) in ids.firstIndex(of: id) ?? .max }
        XCTAssertEqual(owner.first?.anchor, .appNavigation, "The Academy opens on the app's map.")
        XCTAssertEqual(ids.last, WalkthroughStepID.academyHome, "It ends where it can be replayed.")
        XCTAssertLessThan(index("dash.kpis"), index(WalkthroughStepID.clientsTab))
        XCTAssertLessThan(index(WalkthroughStepID.clientsTab), index(WalkthroughStepID.clientSearch))
        XCTAssertLessThan(index(WalkthroughStepID.newClientSave), index(WalkthroughStepID.clientList))
        XCTAssertEqual(index(WalkthroughStepID.clientList) + 1, index(WalkthroughStepID.clientProfile), "Opening a card leads into its profile.")
        XCTAssertEqual(index(WalkthroughStepID.checkOut) + 1, index("co.services"), "Check Out leads into checkout.")
        XCTAssertLessThan(index("co.confirm"), index(WalkthroughStepID.history))
        XCTAssertEqual(index(WalkthroughStepID.visit) + 1, index(WalkthroughStepID.insightsTab))
    }

    /// The tour moves through the app once: after it leaves a screen (or a
    /// client's profile) it never comes back to it.
    func testTheTourNeverReturnsToAScreenItLeft() {
        for role in OnboardingRole.allCases {
            for context in Self.contextMatrix {
                var screens: [String] = []
                for step in WalkthroughController.tour(for: role, context: context) {
                    let screen = "\(step.surface.map { "\($0)" } ?? "none")\(step.route == .demoClientDetail ? ".detail" : "")"
                    if screens.last != screen { screens.append(screen) }
                }
                XCTAssertEqual(Set(screens).count, screens.count, "\(role) \(context): \(screens)")
            }
        }
    }

    /// No control is spotlighted twice.
    func testNoStopRepeatsAnotherStopsSpotlight() {
        for role in OnboardingRole.allCases {
            for context in Self.contextMatrix {
                let anchors = WalkthroughController.tour(for: role, context: context).map(\.anchor)
                XCTAssertEqual(Set(anchors).count, anchors.count, "\(role) \(context): \(anchors)")
            }
        }
    }

    func testEveryTourKeepsItsChaptersTogether() {
        for role in OnboardingRole.allCases {
            for context in Self.contextMatrix {
                let steps = WalkthroughController.tour(for: role, context: context)
                let sequence = lessonSequence(steps)
                XCTAssertEqual(Set(sequence).count, sequence.count, "\(role) \(context): a chapter is split: \(sequence)")
                XCTAssertEqual(sequence, role.tourLessonOrder.filter(sequence.contains), "\(role) \(context)")
                XCTAssertEqual(WalkthroughController.lessons(for: role, context: context), sequence)
                for lesson in sequence {
                    XCTAssertEqual(
                        WalkthroughController.steps(for: lesson, role: role, context: context),
                        steps.filter { $0.lesson == lesson },
                        "\(role) \(lesson)"
                    )
                }
            }
        }
    }

    func testRolesChangeCoachTips() {
        let owner = Dictionary(uniqueKeysWithValues: WalkthroughController.tour(for: .ownerManager, context: .practice).map { ($0.id, $0) })
        let frontDesk = Dictionary(uniqueKeysWithValues: practiceTour.map { ($0.id, $0) })
        for id in ["dash.kpis", "clients.filters", "cd.checkin"] {
            let ownerTip = owner[id]?.coachTip
            let frontDeskTip = frontDesk[id]?.coachTip
            XCTAssertNotNil(ownerTip, id)
            XCTAssertNotNil(frontDeskTip, id)
            XCTAssertNotEqual(ownerTip, frontDeskTip, id)
        }
    }

    func testCheckInLeadsStraightIntoCheckOut() throws {
        for role in OnboardingRole.allCases {
            for context in Self.contextMatrix where context.hasSampleClient && context.sampleClientHasPet {
                let anchors = WalkthroughController.tour(for: role, context: context).map(\.anchor)
                let checkIn = try XCTUnwrap(anchors.firstIndex(of: .cdCheckIn), "\(role) \(context)")
                XCTAssertEqual(anchors[checkIn + 1], .cdCheckOut, "\(role) \(context)")
                XCTAssertEqual(anchors[checkIn - 1], .cdAddPet, "\(role) \(context)")
            }
        }
    }

    // MARK: - Every stop waits for the user

    /// In the practice salon every stop but the optional pet form waits for
    /// the user: a tap on the highlight, or the stop's mission. Each says
    /// what to do in its "Try it" line.
    func testEveryAcademyStopWaitsForTheUser() {
        for step in practiceTour {
            XCTAssertNotNil(step.action, "\(step.id) has no Try it line")
            if step.id == WalkthroughStepID.newClientPets || step.id == WalkthroughStepID.loyaltyPoints {
                XCTAssertFalse(step.requiresTargetAction, "Optional input and the loyalty explanation can continue without acting.")
                continue
            }
            XCTAssertTrue(step.requiresTargetAction, "\(step.id) lets the user tap Next without acting")
            if step.advancesOn != nil {
                XCTAssertTrue(step.allowsTargetInteraction, "\(step.id): the mission's control must be usable")
            }
        }
        let missions = practiceTour.compactMap(\.advancesOn)
        XCTAssertGreaterThanOrEqual(missions.count, 12, "The Academy is hands-on: \(missions)")
    }

    func testMissionsMoveOnWhenTheRealActionHappens() {
        let cases: [(String, WalkthroughTrigger, String)] = [
            (WalkthroughStepID.clientsTab, .clientsTabOpened, WalkthroughStepID.clientSearch),
            (WalkthroughStepID.clientSearch, .clientSearched, WalkthroughStepID.notifications),
            (WalkthroughStepID.notifications, .notificationsClosed, WalkthroughStepID.clientFilters),
            (WalkthroughStepID.clientFilters, .clientFilterChanged, WalkthroughStepID.clientSort),
            (WalkthroughStepID.clientSort, .clientSortChanged, WalkthroughStepID.newClientOwner),
            (WalkthroughStepID.clientList, .clientOpened, WalkthroughStepID.clientProfile),
            (WalkthroughStepID.emergency, .emergencyContactEditorClosed, WalkthroughStepID.clientLoyalty),
            (WalkthroughStepID.addPet, .addPetClosed, WalkthroughStepID.checkIn),
            (WalkthroughStepID.history, .historyRangeChanged, WalkthroughStepID.visit),
            (WalkthroughStepID.visit, .visitOpened, WalkthroughStepID.insightsTab),
            (WalkthroughStepID.insightsTab, .insightsTabOpened, WalkthroughStepID.insightsPeriod),
            (WalkthroughStepID.insightsPeriod, .insightsPeriodChanged, "ins.services")
        ]
        for (stepID, trigger, nextID) in cases {
            let controller = makeController()
            controller.start(practiceTour, at: stepID)
            XCTAssertEqual(controller.currentStep?.id, stepID)
            XCTAssertFalse(controller.currentStepShowsNext, "\(stepID): waits for the user")
            let other: WalkthroughTrigger = trigger == .petAdded ? .clientSortChanged : .petAdded
            XCTAssertFalse(controller.observe(other), "\(stepID): another action doesn't count")
            XCTAssertEqual(controller.currentStep?.id, stepID)
            XCTAssertTrue(controller.observe(trigger), stepID)
            XCTAssertEqual(controller.currentStep?.id, nextID, stepID)
        }
    }

    func testLookOnlyStopsIgnoreTheRealAction() {
        let lookOnly = WalkthroughTourContext(hasSampleClient: true, hasRealClients: true)
        let controller = makeController()
        controller.start(WalkthroughController.tour(for: .ownerManager, context: lookOnly), at: WalkthroughStepID.clientSort)
        XCTAssertFalse(controller.observe(.clientSortChanged))
        XCTAssertEqual(controller.currentStep?.id, WalkthroughStepID.clientSort)
        XCTAssertTrue(controller.currentStepShowsNext)
        XCTAssertNil(controller.currentStep?.action, "No Try it line when nothing can be tried.")
    }

    func testHandsOnStopsNeverDeadEnd() {
        for role in OnboardingRole.allCases {
            for context in Self.contextMatrix {
                let steps = WalkthroughController.tour(for: role, context: context)
                for step in steps where step.requiresTargetAction {
                    // The target never appears: Next shows, or a section that
                    // only exists with data is dropped.
                    let missing = makeController()
                    missing.start(steps, at: step.id)
                    XCTAssertFalse(missing.currentStepShowsNext, "\(role) \(step.id)")
                    missing.noteStepShown(step.id, hasTarget: false)
                    missing.checkTargets()
                    if step.skipsWhenTargetMissing {
                        XCTAssertNotEqual(missing.currentStep?.id, step.id, "\(role) \(step.id): dropped")
                    } else {
                        XCTAssertTrue(missing.currentStepShowsNext, "\(role) \(step.id): no target, so Next shows")
                    }

                    // The target is there but the action can't happen.
                    let blocked = makeController()
                    blocked.start(steps, at: step.id)
                    blocked.noteStepShown(step.id, hasTarget: true)
                    blocked.checkTargets()
                    XCTAssertFalse(blocked.currentStepShowsNext, "\(role) \(step.id)")
                    blocked.releaseActionRequirement(reason: "test")
                    XCTAssertTrue(blocked.currentStepShowsNext, "\(role) \(step.id)")
                }
                if context.isExplainOnly {
                    XCTAssertFalse(steps.contains { $0.requiresTargetAction || $0.allowsTargetInteraction || $0.advancesOn != nil }, "\(role)")
                    XCTAssertFalse(steps.contains { $0.action != nil }, "\(role)")
                }
            }
        }
    }

    func testAStuckMissionOffersNextAfterAMoment() async throws {
        let controller = WalkthroughController()
        controller.targetWatchdogDelay = nil
        controller.missionPatience = .milliseconds(50)
        controller.start(practiceTour, at: WalkthroughStepID.clientSearch)
        XCTAssertFalse(controller.currentStepShowsNext)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.currentStepShowsNext, "Nobody gets stuck on a mission.")
        controller.skip()
    }

    // MARK: - Skip rules at runtime

    func testNeedsAttentionIsSkippedWhenItsSectionIsMissing() {
        let controller = makeController()
        controller.start(practiceTour, at: "dash.attention")
        XCTAssertEqual(controller.currentStep?.id, "dash.attention")
        let count = controller.stepCount

        controller.checkTargets()

        XCTAssertEqual(controller.currentStep?.id, "dash.recent", "No pet is due, so the stop is skipped.")
        XCTAssertEqual(controller.stepCount, count - 1, "The counter no longer counts it.")
        controller.goBack()
        XCTAssertEqual(controller.currentStep?.id, "dash.quick", "Back doesn't land on it again.")
    }

    func testNeedsAttentionStaysWhenItsSectionShows() {
        let controller = makeController()
        controller.start(practiceTour, at: "dash.attention")
        controller.noteStepShown("dash.attention", hasTarget: true)
        controller.checkTargets()
        XCTAssertEqual(controller.currentStep?.id, "dash.attention")
        XCTAssertFalse(controller.isCurrentStepOrphaned)
    }

    func testAMissingSectionIsSkippedInTheDirectionTheUserWasGoingAndOnlyOnce() {
        let controller = makeController()
        controller.start(practiceTour, at: "dash.recent")
        controller.noteStepShown("dash.recent", hasTarget: true)
        controller.goBack()
        XCTAssertEqual(controller.currentStep?.id, "dash.attention")
        controller.checkTargets()
        XCTAssertEqual(controller.currentStep?.id, "dash.quick", "Going Back past a missing section keeps going back.")
        controller.advance()
        XCTAssertEqual(controller.currentStep?.id, "dash.recent", "Next doesn't wait on the missing section a second time.")
    }

    func testTheLastMissingStopOfAChapterStillFinishesIt() {
        let controller = makeController()
        var progress = WalkthroughProgress()
        controller.onProgress = { progress = progress.recording($0) }
        controller.start(practiceTour, at: "dash.recent")
        controller.checkTargets()
        XCTAssertEqual(controller.currentStep?.id, WalkthroughStepID.clientsTab)
        XCTAssertTrue(progress.isComplete(.dailyWorkflow))
        XCTAssertEqual(controller.chapterWin?.chapter, .dailyWorkflow)
    }

    func testSortStopIsSkippedWithAnEmptyClientList() {
        let controller = makeController()
        controller.start(practiceTour, at: WalkthroughStepID.clientSort)
        controller.checkTargets()
        XCTAssertEqual(controller.currentStep?.id, WalkthroughStepID.newClientOwner)
    }

    func testARepeatedTapCannotSkipOrRewindAStop() {
        let controller = makeController()
        let steps = practiceTour
        controller.start(steps)

        // A double-click on the highlight: both taps come from the first stop.
        controller.advance(from: steps[0].id)
        controller.advance(from: steps[0].id)
        XCTAssertEqual(controller.currentStep?.id, steps[1].id)

        controller.advance(from: steps[1].id)
        controller.goBack(from: steps[2].id)
        controller.goBack(from: steps[2].id)
        XCTAssertEqual(controller.currentStep?.id, steps[1].id)
    }

    func testRestartingOrReappearingDoesNotResetARunningTour() {
        let controller = makeController()
        let steps = practiceTour
        controller.start(steps)
        controller.advance()
        controller.advance()
        // A screen appearing again asks to start: the running tour keeps its place.
        controller.start(steps)
        XCTAssertEqual(controller.currentStep?.id, steps[2].id)
    }

    // MARK: - Overlays

    func testEveryStopIsDrawnEvenWhenItsScreenNeverShowsIt() {
        for role in OnboardingRole.allCases {
            for context in Self.contextMatrix {
                let steps = WalkthroughController.tour(for: role, context: context)
                for step in steps where !step.skipsWhenTargetMissing {
                    let controller = makeController()
                    controller.start(steps, at: step.id)
                    controller.checkTargets()
                    XCTAssertTrue(controller.isCurrentStepOrphaned, "\(role) \(step.id)")
                    for rootScope in [WalkthroughOverlayScope.all, .navigation] {
                        XCTAssertTrue(
                            WalkthroughOverlayScope.hostDraws(step, presenting: nil, scope: rootScope, adoptsOrphanedSteps: true, isOrphaned: true),
                            "\(role) \(step.id): the root overlay draws it"
                        )
                    }
                }
            }
        }
    }

    func testTheStepsOwnOverlayTakesOverFromTheRoot() {
        let controller = makeController()
        controller.start(practiceTour, at: "co.services")
        controller.checkTargets()
        XCTAssertTrue(controller.isCurrentStepOrphaned)
        controller.noteStepShown("co.services", hasTarget: false, adopted: true)
        XCTAssertTrue(controller.isCurrentStepOrphaned, "The root keeps drawing it.")
        controller.noteStepShown("co.services", hasTarget: true)
        XCTAssertFalse(controller.isCurrentStepOrphaned, "Checkout opened late: only its overlay draws the step.")
        controller.advance()
        XCTAssertFalse(controller.isCurrentStepOrphaned)
    }

    func testOnlyTheStepsHomeOverlayDrawsItNormally() throws {
        let step = try XCTUnwrap(WalkthroughController.fullTour().first { $0.anchor == .coServices })
        XCTAssertFalse(WalkthroughOverlayScope.hostDraws(step, presenting: nil, scope: .all, adoptsOrphanedSteps: true, isOrphaned: false))
        XCTAssertTrue(WalkthroughOverlayScope.hostDraws(step, presenting: .checkout, scope: .all, adoptsOrphanedSteps: false, isOrphaned: false))
        let visit = try XCTUnwrap(WalkthroughController.fullTour().first { $0.anchor == .cdVisitRow })
        XCTAssertTrue(WalkthroughOverlayScope.detailContent.handles(visit))
        XCTAssertFalse(WalkthroughOverlayScope.rootContent.handles(visit), "The detail column must not draw it a second time.")
        let map = try XCTUnwrap(WalkthroughController.fullTour().first { $0.anchor == .appNavigation })
        XCTAssertTrue(WalkthroughOverlayScope.navigation.handles(map))
        XCTAssertFalse(WalkthroughOverlayScope.rootContent.handles(map))
    }

    // MARK: - Chapters, progress and finishing

    func testFinishingAChapterEarnsAWin() throws {
        let controller = makeController()
        controller.start(practiceTour, at: "dash.recent")
        XCTAssertNil(controller.chapterWin)
        controller.advance()
        let win = try XCTUnwrap(controller.chapterWin)
        XCTAssertEqual(win.chapter, .dailyWorkflow)
        XCTAssertEqual(win.number, 1)
        XCTAssertEqual(win.of, WalkthroughLesson.allCases.count)
        XCTAssertEqual(controller.chapterNumber, 2)

        // Moving within a chapter earns nothing new.
        controller.observe(.clientsTabOpened)
        XCTAssertEqual(controller.chapterWin?.id, win.id)
        controller.endChapterWin(win)
        XCTAssertNil(controller.chapterWin)

        // Going back into a finished chapter earns nothing.
        controller.goBack()
        controller.goBack()
        XCTAssertNil(controller.chapterWin)
    }

    func testMasteredGrowsWithEveryStop() {
        let controller = makeController()
        controller.start(practiceTour)
        XCTAssertEqual(controller.masteredFraction, 0)
        XCTAssertEqual(controller.chapterNumber, 1)
        controller.advance()
        XCTAssertEqual(controller.masteredFraction, 1 / Double(controller.stepCount - 1), accuracy: 0.0001)

        let lastStop = makeController()
        lastStop.start(practiceTour, at: WalkthroughStepID.academyHome)
        XCTAssertEqual(lastStop.masteredFraction, 1, "The last stop reads 100% mastered.")
    }

    func testOnFinishSaysWhetherTheAcademyWasCompleted() {
        let finished = makeController()
        var finishedResult: Bool?
        finished.onFinish = { finishedResult = $0 }
        finished.start(practiceTour, at: WalkthroughStepID.academyHome)
        finished.advance()
        XCTAssertEqual(finishedResult, true)
        XCTAssertTrue(finished.isCelebrating)
        XCTAssertNil(finished.celebratedChapter, "The whole Academy: Academy complete.")

        // Replaying one chapter from Settings celebrates that chapter, not
        // the Academy.
        let replay = makeController()
        let dashboardChapter = practiceTour.filter { $0.lesson == .dailyWorkflow }
        replay.start(dashboardChapter, at: dashboardChapter.last?.id)
        replay.advance()
        XCTAssertTrue(replay.isCelebrating)
        XCTAssertEqual(replay.celebratedChapter, .dailyWorkflow)

        let skipped = makeController()
        var skippedResult: Bool?
        skipped.onFinish = { skippedResult = $0 }
        skipped.start(practiceTour)
        skipped.skip()
        XCTAssertEqual(skippedResult, false)
        XCTAssertFalse(skipped.isCelebrating)
    }

    func testProgressRecordsStopsAndFinishedChapters() {
        let controller = makeController()
        var progress = WalkthroughProgress()
        controller.onProgress = { progress = progress.recording($0) }
        let steps = practiceTour
        controller.start(steps)
        let firstChapterCount = steps.prefix { $0.lesson == .dailyWorkflow }.count

        for _ in 0..<(firstChapterCount - 1) { controller.advance() }
        XCTAssertFalse(progress.isComplete(.dailyWorkflow))
        XCTAssertEqual(progress.lastCompletedStepID, steps[firstChapterCount - 2].id)

        controller.advance()
        XCTAssertTrue(progress.isComplete(.dailyWorkflow))
        XCTAssertEqual(progress.lastCompletedStepID, steps[firstChapterCount - 1].id)
        XCTAssertEqual(progress.continuePosition(in: OnboardingRole.frontDeskGroomer.tourLessonOrder)?.lesson, 2)
        XCTAssertEqual(progress.continuePosition(in: OnboardingRole.frontDeskGroomer.tourLessonOrder)?.of, 5)

        controller.skip()
        XCTAssertTrue(progress.isComplete(.dailyWorkflow), "Skipping keeps what was finished.")
        XCTAssertFalse(progress.isComplete(.clientRecords))
    }

    func testCreatingAClientRecordsTheFormStops() {
        let controller = makeController()
        var events: [WalkthroughProgressEvent] = []
        controller.onProgress = { events.append($0) }
        controller.start(WalkthroughController.tour(for: .ownerManager, context: .practice), at: WalkthroughStepID.newClientOwner)
        controller.completePresentation(.newClient)
        XCTAssertEqual(events.map(\.stepID), [WalkthroughStepID.newClientOwner, WalkthroughStepID.newClientPets, WalkthroughStepID.newClientSave])
        XCTAssertEqual(controller.currentStep?.id, WalkthroughStepID.clientList, "The new client shows up among the cards.")
    }

    func testProgressIsSavedAndReadBack() {
        var progress = WalkthroughProgress()
        progress = progress.recording(WalkthroughProgressEvent(stepID: "dash.recent", lesson: .dailyWorkflow, completesLesson: true))
        progress = progress.recording(WalkthroughProgressEvent(stepID: "nc.pets", lesson: .clientRecords, completesLesson: false))

        AppSettings.storeTourProgress(progress, in: defaults)
        XCTAssertEqual(AppSettings.loadTourProgress(from: defaults), progress)
        XCTAssertEqual(defaults.stringArray(forKey: AppSettingsKeys.tourCompletedLessons), ["dailyWorkflow"])
        XCTAssertEqual(defaults.string(forKey: AppSettingsKeys.tourLastCompletedStepID), "nc.pets")

        AppSettings.storeTourProgress(WalkthroughProgress(), in: defaults)
        XCTAssertEqual(AppSettings.loadTourProgress(from: defaults), WalkthroughProgress())
        XCTAssertNil(defaults.object(forKey: AppSettingsKeys.tourCompletedLessons))

        // Lessons from before the Academy are ignored.
        defaults.set(["dailyWorkflow", "appMap", "settingsAndSafety", "dataOwnership"], forKey: AppSettingsKeys.tourCompletedLessons)
        XCTAssertEqual(AppSettings.loadTourProgress(from: defaults).completedLessons, [.dailyWorkflow])
    }

    func testContinueResumesMidChapterThenAtTheNextChapter() {
        let steps = practiceTour
        XCTAssertEqual(WalkthroughProgress().resumeStepID(in: steps), steps.first?.id)

        var progress = WalkthroughProgress()
        let dashboard = steps.prefix(while: { $0.lesson == .dailyWorkflow })
        for step in dashboard {
            progress = progress.recording(WalkthroughProgressEvent(stepID: step.id, lesson: step.lesson, completesLesson: step.id == dashboard.last?.id))
        }
        XCTAssertEqual(progress.resumeStepID(in: steps), WalkthroughStepID.clientsTab)

        progress = progress.recording(WalkthroughProgressEvent(stepID: WalkthroughStepID.clientSearch, lesson: .clientRecords, completesLesson: false))
        XCTAssertEqual(progress.resumeStepID(in: steps), WalkthroughStepID.notifications, "Continue picks up mid-chapter.")

        // A chapter replayed out of order doesn't pull Continue forward.
        var outOfOrder = WalkthroughProgress()
        outOfOrder = outOfOrder.recording(WalkthroughProgressEvent(stepID: "set.data", lesson: .businessInsights, completesLesson: true))
        XCTAssertEqual(outOfOrder.resumeStepID(in: steps), steps.first?.id)
        XCTAssertEqual(outOfOrder.continuePosition(in: OnboardingRole.frontDeskGroomer.tourLessonOrder)?.lesson, 1)

        let allDone = WalkthroughProgress(completedLessons: Set(WalkthroughLesson.allCases), lastCompletedStepID: WalkthroughStepID.academyHome)
        XCTAssertNil(allDone.resumeStepID(in: steps))
        XCTAssertNil(allDone.continuePosition(in: OnboardingRole.ownerManager.tourLessonOrder))
    }

    func testStartAtAStepIDUsesItOrFallsBackToTheStart() {
        let steps = WalkthroughController.tour(for: .ownerManager, context: .practice)
        let controller = makeController()
        controller.start(steps, at: "set.data")
        XCTAssertEqual(controller.currentStep?.id, "set.data")
        controller.restart(steps, at: "retired.step")
        XCTAssertEqual(controller.currentIndex, 0)
        controller.restart(WalkthroughController.steps(for: .businessInsights, role: .ownerManager, context: .practice))
        XCTAssertEqual(controller.currentStep?.id, WalkthroughStepID.insightsTab)
        XCTAssertTrue(controller.steps.allSatisfy { $0.lesson == .businessInsights })
    }

    func testSavedProgressDrivesTheSettingsLabel() {
        let settings = AppSettings()
        let saved = settings.tourProgress
        defer { settings.tourProgress = saved }

        settings.resetTourProgress()
        XCTAssertEqual(settings.tourProgress, WalkthroughProgress())
        settings.recordTourProgress(WalkthroughProgressEvent(stepID: "dash.recent", lesson: .dailyWorkflow, completesLesson: true))
        XCTAssertEqual(AppSettings.loadTourProgress(), settings.tourProgress, "Written through to UserDefaults.")
        for role in OnboardingRole.allCases {
            let position = settings.tourProgress.continuePosition(in: role.tourLessonOrder)
            XCTAssertEqual(position?.lesson, 2)
            XCTAssertEqual(position?.of, 5)
        }
    }

    // MARK: - Anchors

    private enum Home {
        /// Sidebar row (iPad/Mac) and the tab strip (iPhone).
        case navigation
        /// The whole sidebar and the whole tab strip.
        case navigationBar
        /// A column's root screen: Dashboard, Clients, Insights.
        case rootContent
        /// A toolbar item SwiftUI can't report a frame for: taught in words
        /// from a centered bubble.
        case toolbar
        /// A pushed screen: client details, Settings sections.
        case detail
        /// Inside a sheet the tour opens.
        case sheet(WalkthroughPresentation)
    }

    /// Where each anchor is attached, and the file that attaches it.
    private static let homes: [WalkthroughAnchorID: (Home, String)] = [
        .appNavigation: (.navigationBar, "Pawtrackr/App/Navigation/SidebarView.swift"),
        .dashboard: (.navigation, "Pawtrackr/App/Navigation/SidebarView.swift"),
        .clients: (.navigation, "Pawtrackr/App/Navigation/SidebarView.swift"),
        .insights: (.navigation, "Pawtrackr/App/Navigation/SidebarView.swift"),
        .settings: (.navigation, "Pawtrackr/App/Navigation/SidebarView.swift"),
        .dashKpis: (.rootContent, "Pawtrackr/Features/Dashboard/DashboardView.swift"),
        .dashQuickActions: (.rootContent, "Pawtrackr/Features/Dashboard/DashboardView.swift"),
        .dashNeedsAttention: (.rootContent, "Pawtrackr/Features/Dashboard/DashboardView.swift"),
        .dashRecentClients: (.rootContent, "Pawtrackr/Features/Dashboard/DashboardView.swift"),
        .clientList: (.rootContent, "Pawtrackr/Features/Clients/ClientsView.swift"),
        .clientFilters: (.rootContent, "Pawtrackr/Features/Clients/ClientsView.swift"),
        .clientSort: (.rootContent, "Pawtrackr/Features/Clients/ClientsView.swift"),
        .clientSearch: (.toolbar, "Pawtrackr/Features/Clients/ClientsView.swift"),
        .clientBell: (.toolbar, "Pawtrackr/Features/Clients/ClientsView.swift"),
        .insRevenue: (.rootContent, "Pawtrackr/Features/Insights/InsightsView.swift"),
        .insServices: (.rootContent, "Pawtrackr/Features/Insights/InsightsView.swift"),
        .insPaymentMix: (.rootContent, "Pawtrackr/Features/Insights/InsightsView.swift"),
        .ncOwner: (.sheet(.newClient), "Pawtrackr/Features/Clients/NewClientSheet.swift"),
        .ncPets: (.sheet(.newClient), "Pawtrackr/Features/Clients/NewClientSheet.swift"),
        .ncSave: (.sheet(.newClient), "Pawtrackr/Features/Clients/NewClientSheet.swift"),
        .cdOwner: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdEmergency: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdLoyalty: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdAddPet: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdCheckIn: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdCheckOut: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdHistory: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .cdVisitRow: (.detail, "Pawtrackr/Features/Clients/ClientDetailView.swift"),
        .coServices: (.sheet(.checkout), "Pawtrackr/Features/Checkout/CheckoutView.swift"),
        .coPayment: (.sheet(.checkout), "Pawtrackr/Features/Checkout/CheckoutView.swift"),
        .coConfirm: (.sheet(.checkout), "Pawtrackr/Features/Checkout/CheckoutView.swift"),
        // Settings > Loyalty hands it to the preview card's Try it box.
        .loyaltySimulator: (.detail, "Pawtrackr/Features/Loyalty/LoyaltyManagementView.swift"),
        .setData: (.detail, "Pawtrackr/Features/Settings/SettingsView.swift"),
        .setAbout: (.detail, "Pawtrackr/Features/Settings/SettingsView.swift")
    ]

    private func source(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Pawtrackr.xcodeproj").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw XCTSkip("Repository sources aren't available.") }
            root = parent
        }
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testEveryStopsAnchorIsAttachedWhereItsOverlayCanSeeIt() throws {
        let anchors = Set(WalkthroughController.fullTour().map(\.anchor))
        for anchor in anchors.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let (home, file) = Self.homes[anchor] else {
                XCTFail("\(anchor) has no known home. Add it to the table.")
                continue
            }
            let steps = WalkthroughController.fullTour().filter { $0.anchor == anchor }
            let text = try source(file)
            // Attached there, or handed to a view that attaches it
            // (`LoyaltyJourneyCard()`).
            let literal = text.range(of: #"(walkthrough(Target|Anchor)\(|TourAnchor: )\.\#(anchor.rawValue)[,)]"#, options: .regularExpression) != nil
            let mapped = text.contains("return .\(anchor.rawValue)")
            if case .toolbar = home {
                XCTAssertFalse(literal, "\(anchor): a toolbar item's frame never reaches the overlay")
            } else {
                XCTAssertTrue(literal || mapped, "\(anchor) isn't attached in \(file)")
            }

            for step in steps {
                switch home {
                case .navigation:
                    XCTAssertTrue(WalkthroughOverlayScope.navigation.handles(step), "\(anchor)")
                    XCTAssertTrue(WalkthroughOverlayScope.all.handles(step), "\(anchor)")
                    if case .tabBarItem = step.fallback {} else {
                        XCTFail("\(anchor) needs the iPhone tab-bar fallback")
                    }
                    XCTAssertNil(step.presents)
                case .navigationBar:
                    XCTAssertTrue(WalkthroughOverlayScope.navigation.handles(step), "\(anchor)")
                    XCTAssertNil(step.presents)
                    XCTAssertTrue(try source("Pawtrackr/App/ContentView.swift").contains(".walkthroughAnchor(.appNavigation)"), "The iPhone tab strip carries it too.")
                case .rootContent, .toolbar:
                    XCTAssertTrue(WalkthroughOverlayScope.rootContent.handles(step), "\(anchor)")
                    XCTAssertFalse(WalkthroughOverlayScope.detailContent.handles(step), "\(anchor) would be drawn twice")
                    XCTAssertNil(step.presents)
                case .detail:
                    XCTAssertTrue(WalkthroughOverlayScope.detailContent.handles(step), "\(anchor) isn't drawn on iPad and Mac")
                    XCTAssertFalse(WalkthroughOverlayScope.rootContent.handles(step), "\(anchor) would be drawn twice")
                    XCTAssertNil(step.presents)
                case .sheet(let presentation):
                    XCTAssertEqual(step.presents, presentation, "\(anchor)")
                }
            }
        }
        // The sidebar maps rows to anchors, and the iPhone tab strip uses the same mapping.
        XCTAssertTrue(try source("Pawtrackr/App/Navigation/SidebarView.swift").contains("walkthroughAnchor(item.walkthroughAnchorID)"))
        XCTAssertTrue(try source("Pawtrackr/App/ContentView.swift").contains("walkthroughAnchor(item.walkthroughAnchorID)"))
    }

    func testClientDetailScrollsToEveryDetailStop() {
        let detailStops = WalkthroughController.fullTour().filter { $0.route == .demoClientDetail && $0.presents == nil }
        XCTAssertFalse(detailStops.isEmpty)
        for step in detailStops {
            XCTAssertTrue(ClientDetailView.walkthroughAnchors.contains(step.anchor), "\(step.anchor) is never scrolled into view")
        }
    }

    func testGenderDotsAnchorOnlyOnePetOnClientDetails() throws {
        let dashboard = try source("Pawtrackr/Features/Dashboard/DashboardView.swift")
        XCTAssertFalse(dashboard.contains("walkthroughTarget(.petGenderDots)"), "A second gender-dot anchor competes with the one on client details.")
        let detail = try source("Pawtrackr/Features/Clients/ClientDetailView.swift")
        XCTAssertFalse(detail.contains("walkthroughTarget(.petGenderDots)\n"), "Every pet row would register the same anchor.")
        XCTAssertFalse(detail.contains("walkthroughTarget(.cdVisitRow)\n"), "Every visit row would register the same anchor.")
    }

    // MARK: - Copy

    func testEveryCopyVariantStaysShortAndPlain() {
        for language in [AppLanguageOverride.en, .es] {
            UserDefaults.standard.set(language.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
            var checked = Set<String>()
            for role in OnboardingRole.allCases {
                for context in Self.contextMatrix {
                    for step in WalkthroughController.tour(for: role, context: context) {
                        let key = [step.id, step.directive, step.purpose, step.action ?? "", step.coachTip ?? ""].joined(separator: "|")
                        guard checked.insert(key).inserted else { continue }
                        XCTAssertLessThanOrEqual(step.directive.count, 86, "\(language) \(step.id): \(step.directive)")
                        XCTAssertLessThanOrEqual(step.purpose.count, 190, "\(language) \(step.id): \(step.purpose)")
                        XCTAssertLessThanOrEqual(step.action?.count ?? 0, 86, "\(language) \(step.id): \(step.action ?? "")")
                        XCTAssertLessThanOrEqual(step.coachTip?.count ?? 0, 150, "\(language) \(step.id): \(step.coachTip ?? "")")
                        for text in [step.title, step.directive, step.purpose] + [step.action, step.coachTip].compactMap(\.self) {
                            XCTAssertFalse(text.contains(";"), "\(language) \(step.id): \(text)")
                            XCTAssertFalse(text.contains(" — "), "\(language) \(step.id): \(text)")
                            XCTAssertFalse(text.hasPrefix("tour."), "\(language) \(step.id): missing key \(text)")
                            if language == .es {
                                XCTAssertFalse(text.localizedCaseInsensitiveContains("walkthrough"), "\(step.id): \(text)")
                            }
                        }
                    }
                }
            }
            XCTAssertGreaterThan(checked.count, WalkthroughController.fullTour().count)
        }
    }

    func testCopyMatchesTheScreens() throws {
        UserDefaults.standard.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
        let steps = Dictionary(uniqueKeysWithValues: WalkthroughController.fullTour().map { ($0.id, $0) })

        // Quick Actions has New Client and Check Out, nothing else.
        let quick = try XCTUnwrap(steps["dash.quick"]).purpose
        XCTAssertTrue(quick.contains("New Client") && quick.contains("Check Out"), quick)
        XCTAssertFalse(quick.contains("Reports") || quick.contains("check a pet in"), quick)

        // Checkout takes no tips: the Payment stop explains the total instead.
        let payment = try XCTUnwrap(steps["co.payment"])
        let paymentTip = try XCTUnwrap(payment.coachTip)
        XCTAssertTrue(paymentTip.contains("total"), paymentTip)
        for text in [payment.purpose, paymentTip, try XCTUnwrap(steps[WalkthroughStepID.checkOut]).purpose] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("tip"), text)
        }

        // The emergency card's actions.
        let emergency = try XCTUnwrap(steps[WalkthroughStepID.emergency]).purpose
        for action in ["Call", "Message", "Copy Phone", "Edit", "Delete", "Missing:"] {
            XCTAssertTrue(emergency.contains(action), "\(action): \(emergency)")
        }

        // The filter chips by their real names.
        let filters = try XCTUnwrap(steps[WalkthroughStepID.clientFilters]).directive
        for chip in ClientsViewModel.Filter.allCases {
            XCTAssertTrue(filters.contains(chip.displayName), "\(chip.displayName): \(filters)")
        }
        XCTAssertFalse(filters.contains("overdue"))

        // Last-name-first in the list.
        let sortTip = try XCTUnwrap(steps[WalkthroughStepID.clientSort]?.coachTip)
        XCTAssertTrue(sortTip.contains("Doe Jane"), sortTip)

        // Toolbar stops say where to look, since they can't be highlighted.
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.clientSearch]).directive.contains("at the top"))
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.notifications]).directive.contains("next to search"))

        // The practice salon's own clients.
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.clientList]?.action).contains("Ava Martinez"))
        XCTAssertTrue(try XCTUnwrap(steps[WalkthroughStepID.clientSearch]?.action).contains("Milo"))

        // Encrypted backups have no restore yet, so the Academy never offers them.
        for step in steps.values {
            XCTAssertFalse(step.purpose.localizedCaseInsensitiveContains("encrypt"), step.id)
            XCTAssertFalse(step.directive.localizedCaseInsensitiveContains("encrypt"), step.id)
        }

        // The catalog cannot direct users to removed cloud screens.
        XCTAssertNil(steps["set.icloud"])
        XCTAssertNil(steps["set.devices"])
    }
}
