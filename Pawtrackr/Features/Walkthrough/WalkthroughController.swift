//
//  WalkthroughController.swift
//  Pawtrackr
//
//  Drives the interactive, step-by-step product tour. The tour is a catalog
//  of stops that walks the app screen by screen, in one fixed order:
//  Dashboard, Clients, client details and checkout, Insights, Settings. The
//  stops are grouped into lessons. A role decides which lessons and some
//  coach tips, never the order. What the store and device hold
//  (`WalkthroughTourContext`) decides which stops apply and how they read,
//  and saved progress (`WalkthroughProgress`) lets the tour continue where
//  it stopped or replay a single lesson.
//

import SwiftUI
import SwiftData
import OSLog

/// Identifies an interface element the guided tour can spotlight. A control opts
/// in by attaching `.walkthroughAnchor(.someCase)`; the overlay resolves its live
/// on-screen frame at render time. Tab-bar items (iPhone) can't be anchored in
/// SwiftUI, so those steps fall back to a computed rect — see `SpotlightFallback`.
enum WalkthroughAnchorID: String, CaseIterable, Hashable {
    /// The whole sidebar (Mac/iPad) or tab bar (iPhone).
    case appNavigation
    // Primary navigation (sidebar rows / tab-bar slots)
    case dashboard
    case clients
    case insights
    case settings
    // Dashboard content sections
    case dashKpis
    case dashQuickActions
    case dashNeedsAttention
    case dashRecentClients
    case dashRevenue
    case setupChecklist
    // Insights content cards
    case insKpis
    case insRevenue
    case insMonthly
    case insServices
    case insPaymentMix
    case insCategory
    // New-client form sections
    case ncOwner
    case ncPets
    case ncSave
    // Client-detail sections
    case cdOwner
    case cdEmergency
    case cdLoyalty
    case cdPets
    case petGenderDots
    case emergencyContactBadges
    case cdAddPet
    case cdCheckIn
    case cdCheckOut
    case cdPetHistory
    case cdHistory
    // Checkout flow sections
    case coServices
    case coDetails
    case coPayment
    case coReview
    case coConfirm
    // Settings sections
    case setBusiness
    case setLoyalty
    case setSecurity
    case setData
    case setAbout
    case setStartFresh
    // Client list
    case clientList
    case clientFilters
    case clientSort
    /// Toolbar controls. SwiftUI can't report a toolbar item's frame to the
    /// overlay, so their stops show a centered bubble and teach in words.
    case clientSearch
    case clientBell
    /// The first visit in a client's Recent History.
    case cdVisitRow
    case loyaltySimulator
}

/// A modal the deep-dive tour opens to walk through its contents. The host
/// presents/dismisses it as the relevant steps come and go.
enum WalkthroughPresentation: Equatable {
    case newClient
    case checkout
}

/// A real in-app route the walkthrough can open before showing a step.
enum WalkthroughRoute: Equatable {
    case demoClientDetail
}

/// The real action a hands-on stop waits for. The screen that sees the action
/// reports it with `WalkthroughController.observe(_:)`, and the tour moves on.
enum WalkthroughTrigger: String, Equatable, Sendable {
    /// The client list's Sort by choice changed.
    case clientSortChanged
    /// The emergency contact form was opened from the card and closed again.
    case emergencyContactEditorClosed
    /// A pet was added to the client on screen.
    case petAdded
    /// The Add Pet form was opened and closed again, pet saved or not.
    case addPetClosed
    /// The user picked Clients in the sidebar or tab bar.
    case clientsTabOpened
    /// The user picked Insights in the sidebar or tab bar.
    case insightsTabOpened
    /// Something was typed into the client search.
    case clientSearched
    /// The notifications list was opened from the bell and closed again.
    case notificationsClosed
    /// A filter pill above the client list was picked.
    case clientFilterChanged
    /// A client card was opened.
    case clientOpened
    /// Recent History switched between All and Last 90 Days.
    case historyRangeChanged
    /// A visit in Recent History was opened.
    case visitOpened
    /// The Insights revenue period (7, 30 or 90 days) changed.
    case insightsPeriodChanged
}

/// The Academy's chapters, in the order every tour teaches them: each one
/// covers one part of the app, so the tour never returns to a screen it
/// already left. Every stop belongs to exactly one, and a chapter's stops are
/// contiguous in every tour. Raw values are stored in UserDefaults as
/// finished chapters, so never rename them. A stored value this build doesn't
/// know (retired lessons such as "appMap" or "dataOwnership") is ignored when
/// progress loads.
enum WalkthroughLesson: String, CaseIterable, Hashable, Codable, Sendable {
    /// A: the dashboard and the app's navigation.
    case dailyWorkflow
    /// B: the client list, search, filters and adding a client.
    case clientRecords
    /// C: a client's profile, emergency contacts, loyalty and pets.
    case clientProfiles
    /// D: checkout, payments and visit history.
    case checkoutAndMoney
    /// E: Insights, loyalty points and keeping the salon's data safe.
    case businessInsights

    var title: String {
        switch self {
        case .dailyWorkflow:
            return AppLocalization.localized("tour.chapter.dashboard", value: "Dashboard")
        case .clientRecords:
            return AppLocalization.localized("tour.chapter.directory", value: "Client Directory")
        case .clientProfiles:
            return AppLocalization.localized("tour.chapter.profiles", value: "Profiles & Pets")
        case .checkoutAndMoney:
            return AppLocalization.localized("tour.chapter.visits", value: "Visits & Payments")
        case .businessInsights:
            return AppLocalization.localized("tour.chapter.insights", value: "Insights & Backups")
        }
    }

    var icon: String {
        switch self {
        case .dailyWorkflow: return "square.grid.2x2.fill"
        case .clientRecords: return "person.3.fill"
        case .clientProfiles: return "pawprint.fill"
        case .checkoutAndMoney: return "creditcard.fill"
        case .businessInsights: return "chart.xyaxis.line"
        }
    }
}

extension OnboardingRole {
    /// The chapters this role's Academy teaches, in order. Every role takes
    /// the whole Academy in the same screen order. The role only changes a
    /// few tips.
    var tourLessonOrder: [WalkthroughLesson] {
        WalkthroughLesson.allCases
    }
}

/// The shape of the spotlight cutout around a target.
enum SpotlightShape: Equatable {
    case circle
    case roundedRect(cornerRadius: CGFloat)
}

/// Where to spotlight when no live anchor is registered for a step. SwiftUI does
/// not expose `TabView` tab-item frames, so on iPhone we approximate the bottom
/// tab-bar slot. On Mac/iPad the sidebar rows are real anchors and this is unused.
enum SpotlightFallback: Equatable {
    case none
    /// The `index`-th slot of a bottom tab bar with `count` evenly-spaced items.
    case tabBarItem(index: Int, count: Int)
    /// Top-trailing action in a navigation bar or full-screen cover toolbar.
    case topTrailingAction
    /// Bottom-trailing confirmation action in a macOS sheet footer.
    case bottomTrailingAction
    /// A single compact top-trailing icon button (e.g. a macOS toolbar "+"),
    /// narrower than `.topTrailingAction` so the spotlight lands on just that
    /// control and not a neighbor (like an adjacent delete button).
    case topTrailingIcon
}

/// One coaching stop. Plain-language fields keep every bubble consistent: the
/// directive (what it is / what to tap) and the purpose (why it helps).
struct WalkthroughStep: Identifiable, Equatable {
    /// Stable identifier, e.g. "cd.checkin". Saved progress refers to it, so
    /// it must survive reordering and copy changes. Never reuse or rename one.
    let id: String
    let anchor: WalkthroughAnchorID
    /// Which primary screen this step lives on. The host navigates here before the
    /// step shows, and the screen scrolls `anchor` into view. `nil` for steps whose
    /// target is always on screen (e.g. the nav chrome itself).
    var surface: NavigationItem? = nil
    /// Optional deeper navigation inside a primary screen.
    var route: WalkthroughRoute? = nil
    /// Short headline, e.g. "Clients & Pets".
    let title: String
    /// "What it is": what the highlighted control or card shows.
    let directive: String
    /// "Why it matters": what it does for the user's day.
    var purpose: String
    /// "Try it": the one thing to do to move on, e.g. "Tap Clients in the
    /// sidebar." It never carries the explanation, so the look-only replay
    /// can drop it and keep the rest.
    var action: String? = nil
    /// Learning category for this step.
    var lesson: WalkthroughLesson = .dailyWorkflow
    /// Small practical hint shown below the main explanation.
    var coachTip: String? = nil
    /// SF Symbol shown in the bubble header.
    var icon: String = "hand.tap.fill"
    var shape: SpotlightShape = .roundedRect(cornerRadius: 12)
    /// Spotlight target when `anchor` isn't registered live (iPhone tab bar).
    var fallback: SpotlightFallback = .none
    /// A modal this step lives inside. The host opens it before the step shows
    /// and closes it once the steps that need it are done. `nil` = main UI.
    var presents: WalkthroughPresentation? = nil
    /// Whether the highlighted UI should remain usable. Form and save steps use
    /// this so the walkthrough can teach a real workflow instead of intercepting
    /// the user's tap.
    var allowsTargetInteraction = false
    /// Whether the bubble's Next button should pause until the user acts:
    /// taps the highlighted control, or does the stop's mission. The overlay
    /// still shows Next when the target never appears, when the host says the
    /// action can't happen (`releaseActionRequirement`), after a moment of
    /// patience, and whenever VoiceOver is on.
    var requiresTargetAction = false
    /// Left out of the front desk tour.
    var isOwnerOnly = false
    /// Roles whose tour leaves this stop out. The owner's tour is the
    /// shorter curriculum: it skips the counter-side dashboard lists, the
    /// checkout notes stop, and the secondary Insights charts.
    var excludedRoles: Set<OnboardingRole> = []
    /// Skipped, instead of shown as a centered bubble, when its target isn't
    /// on screen. For sections that only exist with data, like Needs Attention.
    var skipsWhenTargetMissing = false
    /// The real action that moves a hands-on stop on. Next stays available.
    var advancesOn: WalkthroughTrigger? = nil
}

extension WalkthroughStep {
    /// Stops that point at one pet on the tour client, or at its visit.
    var needsTourPet: Bool {
        presents == .checkout || [.cdPets, .petGenderDots, .cdCheckIn, .cdCheckOut, .cdPetHistory].contains(anchor)
    }

    /// The same stop with the highlighted control made look-only, for a tour
    /// on the real salon (the practice salon couldn't open): the bubble shows
    /// Next, a tap on the control advances the tour instead of checking a
    /// pet in, opening checkout or saving a form, and there is no "Try it".
    func explainingOnly() -> WalkthroughStep {
        var step = self
        step.requiresTargetAction = false
        step.allowsTargetInteraction = false
        step.advancesOn = nil
        step.action = nil
        return step
    }
}

/// Stable step identifiers used outside the catalog. Saved progress refers
/// to step IDs, so never rename one.
enum WalkthroughStepID {
    /// The Academy's first stop: the app's navigation.
    static let first = "nav.app"
    static let clientsTab = "nav.clients"
    static let clientSearch = "clients.search"
    static let notifications = "clients.bell"
    static let clientFilters = "clients.filters"
    static let clientSort = "clients.sort"
    static let newClientOwner = "nc.owner"
    static let newClientPets = "nc.pets"
    static let newClientSave = "nc.save"
    static let clientList = "clients.list"
    static let clientProfile = "cd.owner"
    static let emergency = "cd.emergency"
    static let clientLoyalty = "cd.loyalty"
    static let addPet = "cd.addpet"
    static let checkIn = "cd.checkin"
    static let checkOut = "cd.checkout"
    static let history = "cd.history"
    static let visit = "cd.visit"
    static let insightsTab = "nav.insights"
    static let insightsPeriod = "ins.revenue"
    static let loyaltyPoints = "set.loyalty"
    static let backups = "set.data"
    static let academyHome = "set.about"
}

/// What the store and this device hold when a tour starts. It decides which
/// stops apply and how some of them read. Sample and real clients are told
/// apart by the fixed sample UUIDs, never by names.
struct WalkthroughTourContext: Equatable, Sendable {
    /// A sample client (fixed UUID) exists, so the client-detail and
    /// checkout steps have something safe to open.
    var hasSampleClient: Bool
    /// Clients that aren't sample rows exist.
    var hasRealClients: Bool
    /// The sample client the tour opens has at least one pet.
    var sampleClientHasPet: Bool = true
    /// That client's pet is checked in, so checkout has a visit to open.
    var hasActiveSampleVisit: Bool = true
    /// A real PIN is set on this device.
    var isPINSet: Bool = false
    /// The business has a name and a phone or email.
    var isBusinessProfileFilled: Bool = false

    /// A salon holding only the sample clients, with Milo checked in: the
    /// full hands-on tour.
    static let practice = WalkthroughTourContext(hasSampleClient: true, hasRealClients: false)

    /// With real clients around, the tour only explains. It never checks a
    /// pet in, saves a client, or saves a checkout.
    var isExplainOnly: Bool { hasRealClients }

    /// Reads the local store. PIN status comes from AppSettings.
    @MainActor
    static func resolve(
        in context: ModelContext,
        isPINSet: Bool = false
    ) -> WalkthroughTourContext {
        do {
            let tourClient = SampleData.tourClient(in: context)
            let tourPets = tourClient?.pets ?? []
            return WalkthroughTourContext(
                hasSampleClient: try SampleData.sampleClientCount(in: context) > 0,
                hasRealClients: try SampleData.realClientCount(in: context) > 0,
                sampleClientHasPet: !tourPets.isEmpty,
                hasActiveSampleVisit: tourPets.contains { pet in (pet.visits ?? []).contains { $0.endedAt == nil } },
                isPINSet: isPINSet,
                isBusinessProfileFilled: try businessProfileIsFilled(in: context)
            )
        } catch {
            // Unknown store contents: explain only, and open no client.
            return WalkthroughTourContext(
                hasSampleClient: false,
                hasRealClients: true,
                isPINSet: isPINSet
            )
        }
    }

    private static func businessProfileIsFilled(in context: ModelContext) throws -> Bool {
        let configs = try context.fetch(FetchDescriptor<BusinessConfig>())
        return configs.contains { config in
            let hasName = !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContact = [config.phone, config.email].contains { value in
                !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return hasName && hasContact
        }
    }
}

// MARK: - Launch requests

/// What Settings asks the app shell to start, sent with
/// `.replayGettingStartedRequested`.
enum WalkthroughLaunchRequest: Equatable, Sendable {
    /// Replay Getting Started: saved progress cleared, the dashboard
    /// checklist re-armed, and the tour from lesson 1.
    case replayGettingStarted
    /// The tour from lesson 1 with saved progress cleared, e.g. after the
    /// role changed. The checklist is left alone.
    case startOver
    /// The whole tour from where it stopped.
    case continueTour
    /// One lesson on its own.
    case lesson(WalkthroughLesson)

    static let userInfoKey = "walkthroughLaunchRequest"

    var userInfoValue: String {
        switch self {
        case .replayGettingStarted: return "replayGettingStarted"
        case .startOver: return "startOver"
        case .continueTour: return "continue"
        case .lesson(let lesson): return "lesson:\(lesson.rawValue)"
        }
    }

    init?(userInfoValue: String) {
        switch userInfoValue {
        case "replayGettingStarted": self = .replayGettingStarted
        case "startOver": self = .startOver
        case "continue": self = .continueTour
        default:
            guard userInfoValue.hasPrefix("lesson:"),
                  let lesson = WalkthroughLesson(rawValue: String(userInfoValue.dropFirst("lesson:".count)))
            else { return nil }
            self = .lesson(lesson)
        }
    }

    /// A notification without a request, or with one this build doesn't
    /// know, replays Getting Started, as the old single Replay button did.
    init(notification: Notification) {
        let raw = notification.userInfo?[Self.userInfoKey] as? String
        self = raw.flatMap(WalkthroughLaunchRequest.init(userInfoValue:)) ?? .replayGettingStarted
    }

    func post() {
        NotificationCenter.default.post(
            name: .replayGettingStartedRequested,
            object: nil,
            userInfo: [Self.userInfoKey: userInfoValue]
        )
    }
}

// MARK: - Progress

/// One stop the user moved past with Next or the real action.
struct WalkthroughProgressEvent: Equatable, Sendable {
    let stepID: String
    let lesson: WalkthroughLesson
    /// This was the lesson's last stop in the run.
    let completesLesson: Bool
}

/// How far this device got through the tour. Saved by `AppSettings` in
/// UserDefaults, per device. Lessons are finished once their last stop is
/// passed. The last finished stop lets Continue pick up mid-lesson.
struct WalkthroughProgress: Equatable, Sendable {
    var completedLessons: Set<WalkthroughLesson> = []
    var lastCompletedStepID: String? = nil

    func recording(_ event: WalkthroughProgressEvent) -> WalkthroughProgress {
        var next = self
        next.lastCompletedStepID = event.stepID
        if event.completesLesson {
            next.completedLessons.insert(event.lesson)
        }
        return next
    }

    func isComplete(_ lesson: WalkthroughLesson) -> Bool {
        completedLessons.contains(lesson)
    }

    /// The first lesson in `order` that isn't finished.
    func nextLesson(in order: [WalkthroughLesson]) -> WalkthroughLesson? {
        order.first { !isComplete($0) }
    }

    /// "Lesson n of N" for Continue, or nil once every lesson is finished.
    func continuePosition(in order: [WalkthroughLesson]) -> (lesson: Int, of: Int)? {
        guard let next = nextLesson(in: order), let index = order.firstIndex(of: next) else { return nil }
        return (index + 1, order.count)
    }

    /// Where Continue starts in a composed tour: right after the last finished
    /// stop when that is inside the next unfinished lesson, otherwise at that
    /// lesson's first stop. Nil when every lesson in `steps` is finished.
    func resumeStepID(in steps: [WalkthroughStep]) -> String? {
        var order: [WalkthroughLesson] = []
        for step in steps where !order.contains(step.lesson) {
            order.append(step.lesson)
        }
        guard let target = nextLesson(in: order) else { return nil }
        if let last = lastCompletedStepID,
           let index = steps.firstIndex(where: { $0.id == last }),
           steps.indices.contains(index + 1),
           steps[index].lesson == target,
           steps[index + 1].lesson == target {
            return steps[index + 1].id
        }
        return steps.first { $0.lesson == target }?.id
    }
}

// MARK: - Chapter wins

/// A chapter the user just finished, shown as a short reward toast while the
/// Academy carries on into the next one.
struct WalkthroughChapterWin: Equatable, Identifiable {
    let id = UUID()
    let chapter: WalkthroughLesson
    /// 1-based position among the run's chapters.
    let number: Int
    let of: Int
}

// MARK: - Controller

/// Owns tour state. Intentionally UI-framework-light so it can be created once and
/// handed to the overlay. Driven exclusively by SwiftUI on the main thread; the
/// host gates *whether* to start (e.g. only when the app tour hasn't been seen)
/// and persists "seen" via `onFinish` and progress via `onProgress`.
@Observable
@MainActor
final class WalkthroughController {
    private(set) var steps: [WalkthroughStep] = []
    private(set) var currentIndex: Int = 0
    private(set) var isActive: Bool = false
    /// True for ~a couple of seconds after the user FINISHES the tour (not when
    /// they skip), so the host can fire a celebratory confetti burst. The host
    /// clears it via `endCelebration()` once the animation has played.
    private(set) var isCelebrating: Bool = false
    /// The chapter a one-chapter replay just finished, so the celebration
    /// names it. Nil after the whole Academy.
    private(set) var celebratedChapter: WalkthroughLesson?
    /// The chapter just finished, for the host's reward toast. The host
    /// clears it with `endChapterWin(_:)`.
    private(set) var chapterWin: WalkthroughChapterWin?
    private(set) var preferredClientDetailID: PersistentIdentifier?

    /// The last move went backwards. A stop dropped for a missing target keeps
    /// going the same way, and an already-done action doesn't bounce the user
    /// forward again.
    private(set) var lastMoveWasBackward = false
    /// Some overlay drew a bubble for this step.
    private(set) var shownStepID: String?
    /// Some overlay found a target (live anchor or fallback) for this step.
    private(set) var resolvedStepID: String?
    /// Nothing drew this step in time, so the root overlay draws it.
    private(set) var orphanedStepID: String?
    /// A hands-on step that shows Next after all: its target never appeared,
    /// or the host found the action can't happen.
    private(set) var releasedActionStepID: String?

    /// How long a step may go without a drawn bubble or a target before the
    /// fallbacks kick in. `nil` turns the timer off (tests call `checkTargets()`).
    @ObservationIgnored var targetWatchdogDelay: Duration? = .seconds(2)
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// How long a stop that waits for the user's action waits before it
    /// offers Next anyway, so nobody gets stuck on a mission. `nil` turns the
    /// timer off (tests).
    @ObservationIgnored var missionPatience: Duration? = .seconds(15)
    @ObservationIgnored private var patienceTask: Task<Void, Never>?

    /// Invoked exactly once when the tour ends, with true when the user went
    /// through to the last stop and false when they skipped. The host
    /// persists the "tour seen" flag here so it never auto-shows again.
    var onFinish: ((_ completed: Bool) -> Void)?
    /// Invoked for each stop the user moves past going forward.
    @ObservationIgnored var onProgress: ((WalkthroughProgressEvent) -> Void)?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "Walkthrough")

    var currentStep: WalkthroughStep? {
        guard isActive, steps.indices.contains(currentIndex) else { return nil }
        return steps[currentIndex]
    }

    var stepNumber: Int { currentIndex + 1 }
    var stepCount: Int { steps.count }
    /// How far through this run the current stop is: 0 on the first stop,
    /// 1 on the last, so the final stop reads 100% mastered.
    var masteredFraction: Double {
        guard steps.count > 1 else { return steps.isEmpty ? 0 : 1 }
        return Double(currentIndex) / Double(steps.count - 1)
    }
    /// This run's chapters, in order.
    var chapters: [WalkthroughLesson] {
        var order: [WalkthroughLesson] = []
        for step in steps where order.last != step.lesson {
            order.append(step.lesson)
        }
        return order
    }
    /// 1-based position of the current stop's chapter, 0 when inactive.
    var chapterNumber: Int {
        guard let lesson = currentStep?.lesson, let index = chapters.firstIndex(of: lesson) else { return 0 }
        return index + 1
    }
    var isLastStep: Bool { currentIndex >= steps.count - 1 }
    /// Whether an earlier step exists to return to. Drives the Back control so a
    /// user who advanced too quickly can step back and re-read what they missed.
    var canGoBack: Bool { isActive && currentIndex > 0 }

    /// Whether the bubble offers Next. Hands-on steps hide it until the real
    /// action happens, unless the step was released.
    var currentStepShowsNext: Bool {
        guard let step = currentStep else { return false }
        return !step.requiresTargetAction || releasedActionStepID == step.id
    }

    var isCurrentStepOrphaned: Bool {
        guard let step = currentStep else { return false }
        return orphanedStepID == step.id
    }

    /// Begins the tour with the given ordered steps, at `stepID` when it is
    /// one of them. No-op if already running or the list is empty.
    func start(_ steps: [WalkthroughStep], at stepID: String? = nil) {
        guard !isActive, !steps.isEmpty else { return }
        begin(steps, at: stepID)
    }

    /// Starts the tour even if a previous run is active. Used by Settings so a
    /// replay or Continue is an explicit command instead of depending only on
    /// a UserDefaults edge.
    func restart(_ steps: [WalkthroughStep], at stepID: String? = nil) {
        guard !steps.isEmpty else { return }
        begin(steps, at: stepID)
    }

    private func begin(_ steps: [WalkthroughStep], at stepID: String?) {
        self.steps = steps
        currentIndex = stepID.flatMap { id in steps.firstIndex { $0.id == id } } ?? 0
        preferredClientDetailID = nil
        HapticManager.play(.navigation)
        withAnimation(.easeInOut(duration: 0.3)) { isActive = true }
        stepDidChange(backward: false)
    }

    func focusClientDetail(_ clientID: PersistentIdentifier) {
        preferredClientDetailID = clientID
    }

    /// Advances to the next step, or finishes after the last one.
    /// - Parameter stepID: the step the tapped control was drawn for. When
    ///   the tour has already moved on (a double-click on Next, or Next and
    ///   the spotlight both firing), the tap is ignored instead of skipping
    ///   the stop the user hasn't read yet.
    func advance(from stepID: String? = nil) {
        guard isActive, steps.indices.contains(currentIndex) else { return }
        if let stepID, steps[currentIndex].id != stepID { return }
        HapticManager.play(.step)
        let leaving = steps[currentIndex].lesson
        reportCompleted(currentIndex)
        if isLastStep {
            finish(completed: true)
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                currentIndex += 1
            }
            celebrateChapter(ifLeaving: leaving)
            stepDidChange(backward: false)
        }
    }

    /// Returns to the previous step so a user who moved too fast can re-read what
    /// they missed. Navigation, sheets, and scrolling re-drive symmetrically off
    /// the host's `surface`/`route`/`presents`/`anchor` onChange handlers, so a
    /// simple index decrement is enough to reverse the tour. `stepID` guards
    /// against repeated taps the same way as `advance(from:)`.
    func goBack(from stepID: String? = nil) {
        guard isActive, currentIndex > 0, steps.indices.contains(currentIndex) else { return }
        if let stepID, steps[currentIndex].id != stepID { return }
        HapticManager.play(.step)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            currentIndex -= 1
        }
        stepDidChange(backward: true)
    }

    /// Moves past the current modal-backed lesson when the user completes the
    /// real modal action, e.g. creating a client from the New Client sheet.
    func completePresentation(_ presentation: WalkthroughPresentation) {
        guard isActive, currentStep?.presents == presentation else { return }
        HapticManager.play(.step)

        let remainingIndices = steps.indices.drop(while: { $0 <= currentIndex })
        guard let nextIndex = remainingIndices.first(where: { steps[$0].presents != presentation }) else {
            for index in currentIndex..<steps.count { reportCompleted(index) }
            finish(completed: true)
            return
        }

        let leaving = steps[currentIndex].lesson
        for index in currentIndex..<nextIndex { reportCompleted(index) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            currentIndex = nextIndex
        }
        celebrateChapter(ifLeaving: leaving)
        stepDidChange(backward: false)
    }

    /// A screen saw the real action a hands-on stop waits for. Returns true
    /// when that moved the tour on. Look-only stops ignore it.
    @discardableResult
    func observe(_ trigger: WalkthroughTrigger) -> Bool {
        guard let step = currentStep, step.advancesOn == trigger, step.allowsTargetInteraction else { return false }
        Self.log.info("Walkthrough step \(step.id, privacy: .public) completed by \(trigger.rawValue, privacy: .public).")
        advance()
        return true
    }

    /// Replaces one stop's coach tip when its context changes. Writes only
    /// when the text differs.
    func updateCoachTip(_ tip: String?, forStepID stepID: String) {
        guard let index = steps.firstIndex(where: { $0.id == stepID }), steps[index].coachTip != tip else { return }
        steps[index].coachTip = tip
    }

    /// Shows Next on the current hands-on step because the action can't
    /// happen (or already happened) here.
    func releaseActionRequirement(reason: String) {
        guard let step = currentStep, step.requiresTargetAction, releasedActionStepID != step.id else { return }
        Self.log.notice("Walkthrough step \(step.id, privacy: .public) shows Next: \(reason, privacy: .public).")
        releasedActionStepID = step.id
    }

    /// An overlay drew a bubble for `stepID`. `hasTarget` says whether it
    /// found something to spotlight. `adopted` is true for the root overlay
    /// drawing a step no other overlay drew.
    func noteStepShown(_ stepID: String, hasTarget: Bool, adopted: Bool = false) {
        guard currentStep?.id == stepID else { return }
        if shownStepID != stepID { shownStepID = stepID }
        if hasTarget, resolvedStepID != stepID { resolvedStepID = stepID }
        // The step's own overlay turned up late: stop the root from drawing
        // it too, which would dim the screen twice.
        if !adopted, orphanedStepID == stepID { orphanedStepID = nil }
    }

    /// Runs when a step has had its time to appear. A step nobody drew is
    /// handed to the root overlay. A hands-on step with no target shows
    /// Next. A step that only makes sense on screen is dropped from this run.
    func checkTargets() {
        guard isActive, let step = currentStep else { return }
        if resolvedStepID != step.id {
            if step.skipsWhenTargetMissing {
                Self.log.info("Walkthrough step \(step.id, privacy: .public) dropped: its section isn't on screen.")
                dropUnavailableStep()
                return
            }
            Self.log.notice("Walkthrough step \(step.id, privacy: .public) found no target for \(step.anchor.rawValue, privacy: .public).")
            if step.requiresTargetAction, releasedActionStepID != step.id {
                releasedActionStepID = step.id
            }
        }
        if shownStepID != step.id, orphanedStepID != step.id {
            Self.log.notice("Walkthrough step \(step.id, privacy: .public) wasn't drawn by its screen; the root overlay shows it.")
            orphanedStepID = step.id
        }
    }

    /// Ends the tour early.
    func skip() { finish(completed: false) }

    /// Clears the post-completion celebration once its confetti has played.
    func endCelebration() {
        withAnimation(.easeOut(duration: 0.4)) { isCelebrating = false }
    }

    /// Clears a chapter's reward toast once it has shown. A newer win is kept.
    func endChapterWin(_ win: WalkthroughChapterWin) {
        guard chapterWin?.id == win.id else { return }
        withAnimation(.easeOut(duration: 0.3)) { chapterWin = nil }
    }

    /// The tour moved forward out of `chapter` into another one: reward it.
    private func celebrateChapter(ifLeaving chapter: WalkthroughLesson) {
        guard let next = currentStep, next.lesson != chapter else { return }
        let order = chapters
        guard let index = order.firstIndex(of: chapter) else { return }
        HapticManager.notify(.success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            chapterWin = WalkthroughChapterWin(chapter: chapter, number: index + 1, of: order.count)
        }
    }

    /// Takes a stop whose section isn't on screen out of this run and shows
    /// the neighbor in the direction the user was going. Removing it, rather
    /// than hopping over it, means Back and Next never land on it again, so
    /// the tour can't wait on the same empty section twice.
    private func dropUnavailableStep() {
        guard steps.indices.contains(currentIndex) else { return }
        let backward = lastMoveWasBackward && currentIndex > 0
        if !backward {
            // Moving past it forward counts as passing it, so a lesson whose
            // last stop is missing is still recorded as finished.
            reportCompleted(currentIndex)
        }
        guard steps.count > 1 else {
            finish(completed: true)
            return
        }
        if !backward, currentIndex == steps.count - 1 {
            finish(completed: true)
            return
        }
        let leaving = steps[currentIndex].lesson
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            steps.remove(at: currentIndex)
            if backward { currentIndex -= 1 }
        }
        if !backward { celebrateChapter(ifLeaving: leaving) }
        stepDidChange(backward: backward)
    }

    private func reportCompleted(_ index: Int) {
        guard steps.indices.contains(index) else { return }
        let step = steps[index]
        let completesLesson = index == steps.count - 1 || steps[index + 1].lesson != step.lesson
        onProgress?(WalkthroughProgressEvent(stepID: step.id, lesson: step.lesson, completesLesson: completesLesson))
    }

    private func stepDidChange(backward: Bool) {
        if lastMoveWasBackward != backward { lastMoveWasBackward = backward }
        if shownStepID != nil { shownStepID = nil }
        if resolvedStepID != nil { resolvedStepID = nil }
        if orphanedStepID != nil { orphanedStepID = nil }
        if releasedActionStepID != nil { releasedActionStepID = nil }
        scheduleWatchdog()
        schedulePatience()
    }

    private func schedulePatience() {
        patienceTask?.cancel()
        patienceTask = nil
        guard let patience = missionPatience, let step = currentStep, step.requiresTargetAction else { return }
        let stepID = step.id
        patienceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled, let self, self.currentStep?.id == stepID else { return }
            self.releaseActionRequirement(reason: "waited for the user's action")
        }
    }

    private func scheduleWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        // Sections that may not exist (Needs Attention, Recent Clients) get
        // the same time as everything else: a dashboard that is still
        // loading after a tab switch must not lose a stop it would show.
        guard let delay = targetWatchdogDelay, let step = currentStep else { return }
        let stepID = step.id
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.currentStep?.id == stepID else { return }
            self.checkTargets()
        }
    }

    private func finish(completed: Bool) {
        if completed { HapticManager.notify(.success) }
        watchdogTask?.cancel()
        watchdogTask = nil
        patienceTask?.cancel()
        patienceTask = nil
        chapterWin = nil
        withAnimation(.easeOut(duration: 0.25)) { isActive = false }
        // Reward finishing the whole tour with a confetti moment; skipping stays quiet.
        if completed {
            let finishedChapters = chapters
            celebratedChapter = finishedChapters.count == 1 ? finishedChapters.first : nil
            withAnimation(.easeIn(duration: 0.2)) { isCelebrating = true }
        }
        let handler = onFinish
        onFinish = nil
        steps = []
        currentIndex = 0
        preferredClientDetailID = nil
        shownStepID = nil
        resolvedStepID = nil
        orphanedStepID = nil
        releasedActionStepID = nil
        handler?(completed)
    }
}

// MARK: - Tours

extension WalkthroughController {
    /// The add-pet control differs by platform, but the walkthrough only trusts
    /// a live anchor on the visible paw control. A fake toolbar fallback can point
    /// at empty macOS chrome while the real Add Pet button is in the pet section.
    static var addPetSpotlightShape: SpotlightShape {
        #if os(iOS)
        .circle
        #else
        .roundedRect(cornerRadius: 10)
        #endif
    }

    static var addPetSpotlightFallback: SpotlightFallback {
        .none
    }

    /// The New Client confirmation action is top-trailing in iOS full-screen
    /// covers, but bottom-trailing in the macOS sheet footer.
    static var newClientSaveSpotlightFallback: SpotlightFallback {
        #if os(iOS)
        .topTrailingAction
        #else
        .bottomTrailingAction
        #endif
    }

    /// The whole Academy for a role, made safe for what the store holds
    /// (`context`). It normally runs in the practice salon (`PracticeSalon`),
    /// where every stop is hands-on. If that couldn't open it runs on the
    /// real store, and then:
    /// - Client-detail and checkout stops only exist when a sample client is
    ///   there to open (`SampleData.tourClient`). The tour never opens a real
    ///   client.
    /// - With real clients in the store, every stop only explains: nothing
    ///   waits for a real tap, taps on the highlighted control move the tour
    ///   on instead of acting, and the New Client form can't save.
    static func tour(for role: OnboardingRole, context: WalkthroughTourContext) -> [WalkthroughStep] {
        let available = shaped(catalog(role: role, context: context), role: role, context: context)
        return role.tourLessonOrder.flatMap { lesson in available.filter { $0.lesson == lesson } }
    }

    /// One chapter on its own, as Settings replays it.
    static func steps(for lesson: WalkthroughLesson, role: OnboardingRole, context: WalkthroughTourContext) -> [WalkthroughStep] {
        shaped(catalog(role: role, context: context), role: role, context: context).filter { $0.lesson == lesson }
    }

    /// The role's chapters that have at least one stop in this context.
    static func lessons(for role: OnboardingRole, context: WalkthroughTourContext) -> [WalkthroughLesson] {
        let available = Set(tour(for: role, context: context).map(\.lesson))
        return role.tourLessonOrder.filter { available.contains($0) }
    }

    /// Every stop with the owner's copy for a practice salon, grouped by
    /// chapter in `WalkthroughLesson.allCases` order. The source for tests
    /// and for tours.
    static func fullTour() -> [WalkthroughStep] {
        catalog(role: .ownerManager, context: .practice)
    }

    private static func shaped(_ steps: [WalkthroughStep], role: OnboardingRole, context: WalkthroughTourContext) -> [WalkthroughStep] {
        var steps = steps
        if role == .frontDeskGroomer {
            steps.removeAll(where: \.isOwnerOnly)
        }
        steps.removeAll { $0.excludedRoles.contains(role) }
        if !context.hasSampleClient {
            steps.removeAll { $0.route == .demoClientDetail || $0.presents == .checkout }
        } else if !context.sampleClientHasPet {
            steps.removeAll(where: \.needsTourPet)
        }
        if context.isExplainOnly {
            // Nothing will check a pet in, so without a visit already in
            // session there is no checkout to open and show.
            if !context.hasActiveSampleVisit {
                steps.removeAll { $0.presents == .checkout }
            }
            steps = steps.map { $0.explainingOnly() }
        }
        return steps
    }

    private static func text(_ key: String, _ value: String) -> String {
        AppLocalization.localized(key, value: value)
    }

    /// Every stop, with copy for `role`, in chapter order. Each stop reads
    /// "What it is" (`directive`), "Why it matters" (`purpose`) and, on
    /// hands-on stops, "Try it" (`action`). Stops wait for the user: either
    /// a tap on the highlight (look-only stops) or the real action (missions,
    /// `advancesOn`), which is safe because the Academy runs in the practice
    /// salon.
    // swiftlint:disable:next function_body_length
    private static func catalog(role: OnboardingRole, context: WalkthroughTourContext) -> [WalkthroughStep] {
        let isFrontDesk = role == .frontDeskGroomer
        let tapToContinue = text("tour.academy.try.tap_highlight", "Tap the highlight to continue.")
        return [
            // MARK: A. Dashboard
            WalkthroughStep(
                id: WalkthroughStepID.first, anchor: .appNavigation, surface: .dashboard,
                title: text("tour.academy.nav_app.title", "Your App Map"),
                directive: text("tour.academy.nav_app.what", "Dashboard, Clients, Insights and Settings: the four places everything lives."),
                purpose: text("tour.academy.nav_app.why", "Dashboard runs your day, Clients holds every owner and pet, Insights does the math, and Settings keeps the salon set up."),
                action: text("tour.academy.nav_app.try", "Tap the highlighted menu to start."),
                lesson: .dailyWorkflow,
                icon: "map.fill",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: "dash.kpis", anchor: .dashKpis, surface: .dashboard,
                title: text("tour.dash.kpis.title", "Today at a glance"),
                directive: text("tour.academy.dash_kpis.what", "Live cards for In Progress, Completed and today’s Revenue."),
                purpose: text("tour.dash.kpis.purpose", "“In Progress” is pets currently being groomed, “Completed” is how many you have finished today, and “Revenue” is what you have earned so far."),
                action: tapToContinue,
                lesson: .dailyWorkflow,
                coachTip: isFrontDesk
                    ? text("tour.dash.kpis.tip_front_desk", "If In Progress doesn’t match the pets in your care, finish the check-out that was missed.")
                    : text("tour.dash.kpis.tip", "If a number looks off, Recent History and Insights help you reconcile the visit behind it."),
                icon: "clock.fill",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: "dash.quick", anchor: .dashQuickActions, surface: .dashboard,
                title: text("tour.dash.quick.title", "Quick Actions"),
                directive: text("tour.academy.dash_quick.what", "New Client and Check Out, one tap from the dashboard."),
                purpose: text("tour.dash.quick.purpose", "New Client opens the intake form. Check Out lists the pets in session so you can finish a visit and take payment."),
                action: tapToContinue,
                lesson: .dailyWorkflow,
                coachTip: text("tour.dash.quick.tip", "These shortcuts mirror the real front-desk workflow so you can move fast with one hand."),
                icon: "bolt.fill",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: "dash.attention", anchor: .dashNeedsAttention, surface: .dashboard,
                title: text("tour.dash.attention.title", "Needs Attention"),
                directive: text("tour.academy.dash_attention.what", "Pets that are due for their next groom."),
                purpose: text("tour.academy.dash_attention.why", "Call, message and rebook them before they drift to another salon. When everyone is on schedule it says All caught up."),
                action: tapToContinue,
                lesson: .dailyWorkflow,
                icon: "exclamationmark.circle.fill",
                requiresTargetAction: true,
                skipsWhenTargetMissing: true
            ),
            WalkthroughStep(
                id: "dash.recent", anchor: .dashRecentClients, surface: .dashboard,
                title: text("tour.dash.recent.title", "Recent Clients"),
                directive: text("tour.academy.dash_recent.what", "The owners you saw most recently, with their pets."),
                purpose: text("tour.academy.dash_recent.why", "Rebook a regular in seconds. Each pet’s colored dot is blue for male and pink for female."),
                action: tapToContinue,
                lesson: .dailyWorkflow,
                coachTip: text("tour.dash.recent.tip", "Aggressive behavior tags appear in red anywhere the team needs to notice them."),
                icon: "person.2.fill",
                requiresTargetAction: true,
                skipsWhenTargetMissing: true
            ),

            // MARK: B. Client Directory
            WalkthroughStep(
                // Stays on the dashboard: the mission is to open Clients.
                id: WalkthroughStepID.clientsTab, anchor: .clients, surface: .dashboard,
                title: text("tour.academy.nav_clients.title", "Open Clients"),
                directive: text("tour.academy.nav_clients.what", "Clients is your record book for owners, pets and visits."),
                purpose: text("tour.academy.nav_clients.why", "Contact details, pets, safety notes, emergency contacts and every visit for a family live together here."),
                action: text("tour.academy.nav_clients.try", "Tap Clients."),
                lesson: .clientRecords,
                coachTip: text("tour.nav.clients.tip", "One client can have many pets, so multi-pet families stay together."),
                icon: "person.3.fill", fallback: .tabBarItem(index: 1, count: 4),
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .clientsTabOpened
            ),
            WalkthroughStep(
                id: WalkthroughStepID.clientSearch, anchor: .clientSearch, surface: .clients,
                title: text("tour.academy.search.title", "Search"),
                directive: text("tour.academy.search.what", "The search field at the top finds owners, pets and phone numbers."),
                purpose: text("tour.academy.search.why", "At the counter you rarely know where someone sits in the list. Type any part of a name or number and the list narrows as you type."),
                action: text("tour.academy.search.try", "Type Milo in the search field at the top."),
                lesson: .clientRecords,
                icon: "magnifyingglass",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .clientSearched
            ),
            WalkthroughStep(
                id: WalkthroughStepID.notifications, anchor: .clientBell, surface: .clients,
                title: text("tour.academy.bell.title", "Notifications"),
                directive: text("tour.academy.bell.what", "The bell next to search collects what just happened."),
                purpose: text("tour.academy.bell.why", "New clients and finished checkouts land here with the time, so a busy shift never loses track of what changed."),
                action: text("tour.academy.bell.try", "Open the bell, then close it."),
                lesson: .clientRecords,
                icon: "bell.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .notificationsClosed
            ),
            WalkthroughStep(
                id: WalkthroughStepID.clientFilters, anchor: .clientFilters, surface: .clients,
                title: text("tour.clients.filters.title", "Client Filters"),
                directive: text("tour.clients.filters.directive", "Switch between All, Active, Needs Attention, and Missing Info."),
                purpose: text("tour.clients.filters.purpose", "Filters turn a large client book into a working queue, so the front desk can find what needs action right now."),
                action: text("tour.academy.filters.try", "Tap any pill, like Active."),
                lesson: .clientRecords,
                coachTip: isFrontDesk
                    ? text("tour.clients.filters.tip_front_desk", "Start a shift on Needs Attention to see overdue pets nobody has contacted yet.")
                    : text("tour.clients.filters.tip", "Missing Info helps clean up incomplete phone and email records before they cause pickup problems."),
                icon: "line.3.horizontal.decrease.circle.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .clientFilterChanged
            ),
            WalkthroughStep(
                id: WalkthroughStepID.clientSort, anchor: .clientSort, surface: .clients,
                title: text("tour.clients.sort.title", "Sort & Name Order"),
                directive: text("tour.clients.sort.directive", "Sort by changes the order and how names read."),
                purpose: text("tour.academy.sort.why", "Last Name is the default and lists last names first. First Name, Pet’s Name, Last Visit and Newest are one tap away."),
                action: text("tour.academy.sort.try", "Pick First Name and watch the names flip."),
                lesson: .clientRecords,
                coachTip: text("tour.clients.sort.tip", "Sorted by Last Name, “Jane Doe” shows as “Doe Jane” in the list. Her profile still reads “Jane Doe”."),
                icon: "arrow.up.arrow.down",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                skipsWhenTargetMissing: true,
                advancesOn: .clientSortChanged
            ),
            WalkthroughStep(
                // Next unlocks once a first name is typed (NewClientSheet).
                id: WalkthroughStepID.newClientOwner, anchor: .ncOwner, surface: .clients,
                title: text("tour.academy.nc_owner.title", "Add a client"),
                directive: text("tour.academy.nc_owner.what", "The New Client form starts with the person who books and pays."),
                purpose: text("tour.nc.owner.purpose", "Name, phone, email, address, and emergency contacts help you confirm appointments, follow up, and keep the right contact details on receipts and exports."),
                action: text("tour.academy.nc_owner.try", "Type a first name to continue."),
                lesson: .clientRecords,
                coachTip: text("tour.nc.owner.tip", "Only a name is required. Add the rest now or fill it in later."),
                icon: "person.text.rectangle",
                presents: .newClient,
                allowsTargetInteraction: true,
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.newClientPets, anchor: .ncPets, surface: .clients,
                title: text("tour.nc.pets.title", "Add their pets"),
                directive: text("tour.nc.pets.directive", "Capture the details the team needs before handling."),
                purpose: text("tour.nc.pets.purpose", "Add each pet’s name, photo, species, breed, color, gender and birthday. Record handling observations during checkout."),
                action: text("tour.academy.nc_pets.try", "Add a pet if you like, then tap Next."),
                lesson: .clientRecords,
                coachTip: text("tour.nc.pets.tip", "A good pet profile turns the next visit into a quick check-in instead of a memory test."),
                icon: "pawprint.fill",
                presents: .newClient,
                allowsTargetInteraction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.newClientSave, anchor: .ncSave, surface: .clients,
                title: text("tour.nc.save.title", "Save the client"),
                directive: text("tour.academy.nc_save.what", "The Create button finishes the form."),
                purpose: text("tour.academy.nc_save.why", "Create saves the client for check-in, services, checkout, receipts and history. In the Academy it lives only in the practice salon."),
                action: text("tour.academy.nc_save.try", "Tap Create."),
                lesson: .clientRecords,
                icon: "checkmark.circle.fill",
                fallback: newClientSaveSpotlightFallback,
                presents: .newClient,
                allowsTargetInteraction: true,
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.clientList, anchor: .clientList, surface: .clients,
                title: text("tour.academy.list.title", "Client cards"),
                directive: text("tour.academy.list.what", "Each card shows the owner’s initials, phone and pets."),
                purpose: text("tour.academy.list.why", "Clients with a pet checked in come first, under In Progress. Pet names sit in the same blue and pink capsules everywhere."),
                action: text("tour.academy.list.try", "Tap Ava Martinez’s card to open her profile."),
                lesson: .clientRecords,
                icon: "rectangle.stack.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                skipsWhenTargetMissing: true,
                advancesOn: .clientOpened
            ),

            // MARK: C. Profiles & Pets
            WalkthroughStep(
                id: WalkthroughStepID.clientProfile, anchor: .cdOwner, surface: .clients, route: .demoClientDetail,
                title: text("tour.academy.cd_owner.title", "Client profile"),
                directive: text("tour.academy.cd_owner.what", "The owner’s header, with call, message, email and map buttons."),
                purpose: text("tour.academy.cd_owner.why", "Confirm details at booking or pickup and reach the owner in one tap. A red Caution banner under it means a pet is flagged aggressive."),
                action: tapToContinue,
                lesson: .clientProfiles,
                icon: "person.crop.rectangle.stack.fill",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.emergency, anchor: .cdEmergency, surface: .clients, route: .demoClientDetail,
                title: text("tour.cd.emergency.title", "Emergency Contacts"),
                directive: text("tour.academy.cd_emergency.what", "Backup people staff can call when the owner can’t be reached."),
                purpose: text("tour.cd.emergency.purpose", "Each backup person shows relation and phone. Call dials them, and the row’s menu offers Message, Copy Phone, Edit, and Delete. A “Missing:” note lists what’s left to add."),
                action: text("tour.academy.cd_emergency.try", "Tap + to add a backup contact, then save or close the form."),
                lesson: .clientProfiles,
                icon: "phone.badge.plus",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .emergencyContactEditorClosed
            ),
            WalkthroughStep(
                id: WalkthroughStepID.clientLoyalty, anchor: .cdLoyalty, surface: .clients, route: .demoClientDetail,
                title: text("tour.academy.cd_loyalty.title", "Loyalty points"),
                directive: text("tour.academy.cd_loyalty.what", "Loyalty & Rewards shows this client’s points. The badge color shows their tier."),
                purpose: text("tour.academy.cd_loyalty.why", "Every checkout adds points on its own, by default from what the client pays. Points buy rewards like a visit credit, so regulars have a reason to come back."),
                action: tapToContinue,
                lesson: .clientProfiles,
                coachTip: text("tour.cd.loyalty.tip", "At checkout’s Payment step, choose a reward. Review the lower total. Points are used only when you confirm payment."),
                icon: "crown.fill",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.addPet, anchor: .cdAddPet, surface: .clients, route: .demoClientDetail,
                title: text("tour.academy.cd_addpet.title", "Pets & Add Pet"),
                directive: text("tour.academy.cd_addpet.what", "Pet cards show profile details, handling cues and birthdays. Add Pet adds another."),
                purpose: text("tour.academy.cd_addpet.why", "Every pet keeps its own photo, health notes, behavior tags and visit history, so multi-pet families stay organized."),
                action: text("tour.academy.cd_addpet.try", "Tap Add Pet, then save a pet or close the form."),
                lesson: .clientProfiles,
                coachTip: text("tour.cd.addpet.tip", "Green: calm/cooperative. Orange: anxious. Blue: nervous. Purple: special needs. Red: aggression. Always read priority warnings."),
                icon: "pawprint.fill",
                shape: addPetSpotlightShape,
                fallback: addPetSpotlightFallback,
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .addPetClosed
            ),
            WalkthroughStep(
                id: WalkthroughStepID.checkIn, anchor: .cdCheckIn, surface: .clients, route: .demoClientDetail,
                title: text("tour.cd.checkin.title", "Check In"),
                directive: text("tour.academy.cd_checkin.what", "Starts a visit for a pet that just arrived."),
                purpose: text("tour.cd.checkin.purpose", "Check In creates an active visit, starts the timer, changes the pet status to in session, and makes checkout available when the groom is finished."),
                action: text("tour.academy.cd_checkin.try", "Tap Check In on the highlighted pet."),
                lesson: .clientProfiles,
                coachTip: isFrontDesk
                    ? text("tour.cd.checkin.tip", "Use it when the pet is physically in your care so duration and dashboard counts stay accurate.")
                    : text("tour.cd.checkin.tip_owner", "Check-in times set visit length and today’s counts, so ask the team to check in on arrival."),
                icon: "play.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.checkOut, anchor: .cdCheckOut, surface: .clients, route: .demoClientDetail,
                title: text("tour.cd.checkout.title", "Check Out"),
                directive: text("tour.academy.cd_checkout.what", "Opens checkout for a pet that is in session."),
                purpose: text("tour.cd.checkout.purpose", "Check Out opens after a pet is checked in. That checkout process records services, notes, photos, payment method, receipt details, and a final review before saving."),
                action: text("tour.academy.cd_checkout.try", "Tap Check Out on the highlighted pet."),
                lesson: .clientProfiles,
                coachTip: text("tour.cd.checkout.tip", "If this button is dimmed, the pet has not been checked in yet."),
                icon: "stop.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: true
            ),

            // MARK: D. Visits & Payments
            WalkthroughStep(
                id: "co.services", anchor: .coServices, surface: .clients, route: .demoClientDetail,
                title: text("tour.co.services.title", "Checkout: Services"),
                directive: text("tour.co.services.directive", "Build the ticket from the real service menu."),
                purpose: text("tour.co.services.purpose", "Services is where you choose the main groom and add-ons. Those selections build the subtotal with exact Decimal money math before the visit moves to notes, payment, and review."),
                action: tapToContinue,
                lesson: .checkoutAndMoney,
                coachTip: text("tour.co.services.tip", "Main services and add-ons come from Settings, so your checkout stays consistent with your shop menu."),
                icon: "list.bullet.rectangle.portrait.fill",
                presents: .checkout,
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: "co.payment", anchor: .coPayment, surface: .clients, route: .demoClientDetail,
                title: text("tour.co.payment.title", "Checkout: Payment"),
                directive: text("tour.co.payment.directive", "Confirm the amount and how the client paid."),
                purpose: text("tour.co.payment.purpose", "Payment captures the final amount, payment method, and any required card or transfer reference so receipts and bookkeeping match the real transaction."),
                action: tapToContinue,
                lesson: .checkoutAndMoney,
                coachTip: text("tour.co.payment.tip", "The total fills in from the services. Type over it for a discount or an extra charge."),
                icon: "creditcard.fill",
                presents: .checkout,
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: "co.confirm", anchor: .coConfirm, surface: .clients, route: .demoClientDetail,
                title: text("tour.co.confirm.title", "Confirm & Save"),
                directive: text("tour.co.confirm.directive", "This is the real checkout finish line."),
                purpose: text("tour.academy.co_confirm.why", "Confirm & Pay saves the payment, updates history and insights, and prepares the receipt. In the Academy nothing is charged or saved."),
                action: tapToContinue,
                lesson: .checkoutAndMoney,
                coachTip: text("tour.co.confirm.tip", "After payment, loyalty points post to the client profile automatically."),
                icon: "checkmark.seal.fill",
                presents: .checkout,
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.history, anchor: .cdHistory, surface: .clients, route: .demoClientDetail,
                title: text("tour.cd.history.title", "Recent History"),
                directive: text("tour.academy.cd_history.what", "Every finished visit for this client, newest first."),
                purpose: text("tour.academy.cd_history.why", "Answer pricing questions, repeat a favorite service and check notes before the next groom."),
                action: text("tour.academy.cd_history.try", "Tap Last 90 Days."),
                lesson: .checkoutAndMoney,
                icon: "clock.arrow.circlepath",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .historyRangeChanged
            ),
            WalkthroughStep(
                id: WalkthroughStepID.visit, anchor: .cdVisitRow, surface: .clients, route: .demoClientDetail,
                title: text("tour.academy.visit.title", "A visit record"),
                directive: text("tour.academy.visit.what", "Each visit shows its services, the Paid badge, how it was paid and how long it took."),
                purpose: text("tour.academy.visit.why", "Open one to see the whole ticket: every service and price, the payment reference, notes and photos."),
                action: text("tour.academy.visit.try", "Tap the highlighted visit to open it."),
                lesson: .checkoutAndMoney,
                icon: "doc.text.magnifyingglass",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .visitOpened
            ),

            // MARK: E. Insights & Backups
            WalkthroughStep(
                // No surface: the visit just opened stays on screen while
                // the mission is to open Insights from the sidebar or tab bar.
                id: WalkthroughStepID.insightsTab, anchor: .insights,
                title: text("tour.academy.nav_insights.title", "Open Insights"),
                directive: text("tour.academy.nav_insights.what", "Insights turns finished checkouts into charts."),
                purpose: text("tour.academy.nav_insights.why", "Revenue, top services, payment mix and returning clients update on their own after every visit."),
                action: text("tour.academy.nav_insights.try", "Tap Insights."),
                lesson: .businessInsights,
                icon: "chart.bar.fill", fallback: .tabBarItem(index: 2, count: 4),
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .insightsTabOpened
            ),
            WalkthroughStep(
                id: WalkthroughStepID.insightsPeriod, anchor: .insRevenue, surface: .insights,
                title: text("tour.academy.ins_revenue.title", "Revenue trend"),
                directive: text("tour.academy.ins_revenue.what", "Revenue over 7, 30 or 90 days, with the number of visits."),
                purpose: text("tour.academy.ins_revenue.why", "Tell a strong stretch from a slow one and see where the business is heading."),
                action: text("tour.academy.ins_revenue.try", "Tap 30D to change the period."),
                lesson: .businessInsights,
                icon: "dollarsign.circle.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: true,
                advancesOn: .insightsPeriodChanged
            ),
            WalkthroughStep(
                id: "ins.services", anchor: .insServices, surface: .insights,
                title: text("tour.ins.services.title", "Service Profitability"),
                directive: text("tour.ins.services.directive", "Learn what earns the most."),
                purpose: text("tour.ins.services.purpose", "See which services drive revenue, average ticket size, and repeat demand so you can promote the winners and rethink the rest."),
                action: tapToContinue,
                lesson: .businessInsights,
                coachTip: text("tour.ins.services.tip", "Keep your service menu tidy in Settings so these charts stay meaningful."),
                icon: "scissors",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: "ins.payment", anchor: .insPaymentMix, surface: .insights,
                title: text("tour.ins.payment.title", "Payment Mix"),
                directive: text("tour.ins.payment.directive", "Know how clients pay."),
                purpose: text("tour.ins.payment.purpose", "Cash, card, debit, Zelle, or transfer: knowing your mix helps you plan deposits and spot processing-fee patterns."),
                action: tapToContinue,
                lesson: .businessInsights,
                icon: "creditcard.fill",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                // A read-only explanation of the automatic visit lifecycle.
                id: WalkthroughStepID.loyaltyPoints, anchor: .loyaltySimulator, surface: .settings,
                title: text("tour.academy.set_loyalty.title", "How points add up"),
                directive: text("tour.academy.set_loyalty.what", "Check in, complete the visit and record payment. Points are saved automatically."),
                purpose: text("tour.academy.set_loyalty.why", "Every award is linked to a completed, paid visit and appears in the client’s profile and history."),
                action: text("tour.academy.set_loyalty.try", "Follow the three steps, then continue."),
                lesson: .businessInsights,
                coachTip: text("tour.academy.set_loyalty.tip", "No manual entry is needed. Open How points are calculated for the salon’s current rules."),
                icon: "star.circle.fill",
                allowsTargetInteraction: true,
                requiresTargetAction: false
            ),
            WalkthroughStep(
                id: WalkthroughStepID.backups, anchor: .setData, surface: .settings,
                title: text("tour.academy.set_data.title", "Export your data"),
                directive: text("tour.academy.set_data.what", "Settings exports your clients and visits as spreadsheet files."),
                purpose: text("tour.academy.set_data.why", "Your records live on this device. An export is a copy you control, for bookkeeping, your accountant or a backup."),
                action: tapToContinue,
                lesson: .businessInsights,
                icon: "square.and.arrow.up",
                requiresTargetAction: true
            ),
            WalkthroughStep(
                id: WalkthroughStepID.academyHome, anchor: .setAbout, surface: .settings,
                title: text("tour.academy.set_about.title", "Your Academy home"),
                directive: text("tour.academy.set_about.what", "Continue, replay a chapter or re-run the whole Academy from here."),
                purpose: text("tour.academy.set_about.why", "Train new staff any time. The Academy always runs in a practice salon, so nobody changes your real clients while learning."),
                action: text("tour.academy.set_about.try", "Tap the highlight to graduate."),
                lesson: .businessInsights,
                icon: "graduationcap.fill",
                requiresTargetAction: true
            )
        ]
    }

}


extension WalkthroughStep {
    /// Reveals the menu only for a lesson that points at a navigation destination.
    var showsNavigation: Bool {
        switch anchor {
        case .appNavigation, .dashboard, .clients, .insights, .settings: return true
        default: return false
        }
    }
}
