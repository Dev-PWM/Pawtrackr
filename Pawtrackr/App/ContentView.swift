//
//  ContentView.swift
//  Pawtrackr
//
//  Cross-platform main content view.
//  Uses NavigationSplitView for macOS/iPad and TabView for iPhone.
//

import SwiftUI
import SwiftData
import OSLog
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    private enum SheetDestination: Identifiable {
        case newClient
        case recentHistory(RecentHistoryViewModel.Scope?)

        var id: String {
            switch self {
            case .newClient:
                return "new-client"
            case .recentHistory(let scope):
                return "recent-history-\(scope?.rawValue ?? "all")"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var appSettings
    @Environment(DataStoreService.self) private var dataStore
    /// The Academy's sandbox (RootView owns it). Open while the tour runs.
    @Environment(PracticeSalon.self) private var practiceSalon: PracticeSalon?

    @State private var router = NavigationRouter()
    @SceneStorage("content.sidebarSelection") private var sidebarSelectionRaw = NavigationItem.dashboard.rawValue
    @SceneStorage("content.tabSelection") private var tabSelectionRaw = NavigationItem.dashboard.rawValue
    @State private var presentedSheet: SheetDestination?
    @State private var isWalkthroughDrivingSheet = false
    /// The interactive spotlight tour, hosted at the navigation root so it can
    /// dim and spotlight the sidebar (Mac/iPad) or tab bar (iPhone).
    @State private var walkthrough = WalkthroughController()
    @State private var walkthroughStartTask: Task<Void, Never>?
    @State private var isExplicitWalkthroughReplayPending = false
    /// The running tour is the whole Academy, not one replayed chapter, so
    /// finishing it earns the graduate badge.
    @State private var isRunningFullAcademy = false
    /// The sample client the tour last opened, so later stops can tell
    /// whether client details are still showing it.
    @State private var walkthroughRoutedClientID: PersistentIdentifier?
    /// Last-handled (kind, uuid, timestamp) used to dedupe near-simultaneous
    /// navigation requests coming from both `.onReceive` and `consumePendingNavigation`
    /// at app launch / cold-start time.
    @State private var lastNavigationDedupeKey: String?
    @State private var lastNavigationDedupeAt: Date = .distantPast
    /// `defaultLaunchTab` only applies once per cold launch; flipping a tab
    /// later must not snap the user back to their pinned default.
    @State private var hasAppliedDefaultLaunchTab = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var sharedNamespace

    private var sidebarSelection: NavigationItem? {
        get { NavigationItem(rawValue: sidebarSelectionRaw) ?? .dashboard }
        nonmutating set { sidebarSelectionRaw = newValue?.rawValue ?? NavigationItem.dashboard.rawValue }
    }

    private var tabSelection: NavigationItem {
        get { NavigationItem(rawValue: tabSelectionRaw) ?? .dashboard }
        nonmutating set { tabSelectionRaw = newValue.rawValue }
    }

    private var sidebarSelectionBinding: Binding<NavigationItem?> {
        Binding(
            get: { sidebarSelection },
            set: {
                if sidebarSelection != $0 { HapticManager.play(.navigation) }
                sidebarSelection = $0
            }
        )
    }

    private var tabSelectionBinding: Binding<NavigationItem> {
        Binding(
            get: { tabSelection },
            set: {
                if tabSelection != $0 { HapticManager.play(.navigation) }
                tabSelection = $0
            }
        )
    }

    var body: some View {
        lifecycleContent
    }

    private var lifecycleContent: some View {
        sheetContent
            .onAppear {
                handleContentAppear()
            }
            .onChange(of: appSettings.hasSeenAppTour) { _, seen in
                // Pick up the OnboardingViewModel (or "Replay Getting Started")
                // arming the tour without requiring a fresh ContentView appear.
                if !seen, !isExplicitWalkthroughReplayPending {
                    startWalkthroughIfReady()
                }
            }
    }

    private var sheetContent: some View {
        notificationContent
            .adaptiveCover(item: $presentedSheet) { destination in
                switch destination {
                case .newClient:
                    // SwiftUI does not reliably forward the `.environment(walkthrough)`
                    // injected on the root into a fullScreenCover/sheet, so the in-sheet
                    // guided-tour overlay never saw the controller (it read nil and
                    // silently skipped the spotlight). Re-inject it explicitly here so
                    // the New Client tour steps render inside the cover on iOS and macOS.
                    NewClientSheet(modelContext: modelContext)
                        .environment(walkthrough)
                case .recentHistory(let scope):
                    NavigationStack {
                        RecentHistoryView(initialScope: scope)
                    }
                }
            }
    }

    private var notificationContent: some View {
        navigationStateContent
            .onReceive(NotificationCenter.default.publisher(for: .showNewClientSheet)) { _ in
                consumePendingNewClientRequest()
                presentedSheet = .newClient
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToPet)) { notification in
                handleNavigation(notification, type: .pet)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToClient)) { notification in
                handleNavigation(notification, type: .client)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clientDidCreate)) { notification in
                continueWalkthroughAfterClientCreate(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clientOpenRequested)) { notification in
                guard let id = notification.requestedClientID,
                      let client = modelContext.model(for: id) as? Client else { return }
                selectClientsSurface()
                router.popClientsToRoot()
                router.navigateToClient(client)
                NotificationCenter.default.post(name: .clientDidCreate, object: nil, userInfo: [
                    ClientDidCreateKey.clientID.rawValue: id,
                    ClientDidCreateKey.phase.rawValue: ClientDidCreatePhase.navigated.rawValue
                ])
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectNavigationItem)) { notification in
                handleNavigationSelection(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .replayGettingStartedRequested)) { notification in
                launchWalkthrough(WalkthroughLaunchRequest(notification: notification))
            }
    }

    private var navigationStateContent: some View {
        walkthroughContent
            .environment(router)
            .onChange(of: appSettings.currencySymbol) { _, newValue in
                Formatters.updateCurrencySymbol(newValue)
            }
            .onChange(of: sidebarSelection) { _, newValue in
                if let newValue {
                    router.activeNavigationItem = newValue
                    reportTabMission(newValue)
                }
            }
            .onChange(of: tabSelection) { _, newValue in
                router.activeNavigationItem = newValue
                reportTabMission(newValue)
            }
    }

    private var walkthroughContent: some View {
        rootContent
            // Screens keep view models built on the store they opened with.
            // Rebuild them when the window moves to or from the practice
            // salon. The tour and its overlay live above, and carry on.
            .id(practiceSalon?.session?.id)
            // The root overlay also draws, centered, any step its own screen
            // never drew, so the tour can't vanish without Back/Skip/Next.
            .walkthroughOverlay(walkthrough, scope: rootOverlayScope, adoptsOrphanedSteps: true)
            // Confetti moment when the user finishes the whole tour. Sits above the
            // walkthrough overlay so it plays as the tour dismisses, then clears
            // itself after the burst.
            .overlay {
                if walkthrough.isCelebrating {
                    WalkthroughCelebrationView(chapter: walkthrough.celebratedChapter)
                        .transition(.opacity)
                }
            }
            .onChange(of: walkthrough.isCelebrating) { _, celebrating in
                guard celebrating else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.4))
                    walkthrough.endCelebration()
                }
            }
            // A medal when an Academy chapter ends; the tour carries on under it.
            .overlay(alignment: .top) {
                if let win = walkthrough.chapterWin {
                    WalkthroughChapterWinToast(win: win)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: win.id) {
                            try? await Task.sleep(for: .seconds(2.4))
                            walkthrough.endChapterWin(win)
                        }
                }
            }
            .environment(walkthrough)
            // The deep-dive tour drives navigation for every step, not only when
            // the high-level surface value changes. Consecutive steps often live
            // on the same screen (Clients -> Client Filters), and replaying from
            // another tab must still move the user to the step's real target.
            .onChange(of: walkthrough.currentStep?.id) { _, _ in
                synchronizeWalkthroughStep(walkthrough.currentStep)
            }
            .onChange(of: walkthrough.isActive) { _, isActive in
                if isActive {
                    synchronizeWalkthroughStep(walkthrough.currentStep)
                } else {
                    closeWalkthroughPresentationIfNeeded()
                    columnVisibility = .doubleColumn
                    walkthroughRoutedClientID = nil
                }
            }
            // Pushed screens and open sheets hold records from the store
            // they came from: start clean when the window switches between
            // the real salon and the practice one.
            .onChange(of: practiceSalon?.session?.id) { _, _ in
                router.popAllToRoot()
                presentedSheet = nil
                isWalkthroughDrivingSheet = false
                walkthroughRoutedClientID = nil
            }
    }

    private func handleContentAppear() {
        if !hasAppliedDefaultLaunchTab && !AppRuntime.isUITesting,
           let tab = NavigationItem(rawValue: appSettings.defaultLaunchTab) {
            sidebarSelection = tab
            tabSelection = tab
        }
        hasAppliedDefaultLaunchTab = true
        router.activeNavigationItem = horizontalSizeClass == .compact ? tabSelection : (sidebarSelection ?? .dashboard)
        // Each stop moved past is saved, so Settings can continue the tour
        // where it stopped.
        let settings = appSettings
        walkthrough.onProgress = { event in
            settings.recordTourProgress(event)
        }
        applyUITestLaunchOverrides()
        consumePendingNewClientRequest()
        consumePendingNavigation()
        startWalkthroughIfReady()
    }

    private func startWalkthroughIfReady() {
        guard canStartWalkthroughInCurrentRuntime else { return }
        // Don't start over a modal (onboarding cover, what's-new, a sheet) —
        // wait until the navigation chrome is the front-most thing so the
        // spotlight can actually land on the sidebar / tab bar.
        guard presentedSheet == nil else { return }
        guard shouldAutoStartWalkthrough, !walkthrough.isActive else { return }
        // The tour runs in the practice salon. Opening it now lets the window
        // switch stores during the delay below.
        openPracticeSalonForTour()
        // Brief delay lets the post-onboarding transition settle so the sidebar /
        // tab-bar anchors are measured in their final positions before we spotlight.
        walkthroughStartTask?.cancel()
        walkthroughStartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            // Cancelled by a newer start, which owns the practice salon now.
            guard !Task.isCancelled else { return }
            guard canStartWalkthroughInCurrentRuntime,
                  shouldAutoStartWalkthrough,
                  !walkthrough.isActive,
                  presentedSheet == nil
            else {
                closePracticeSalonIfNoTour()
                return
            }
            selectSurface(.dashboard, resetPath: true)
            revealSplitSidebarForWalkthroughIfNeeded()
            walkthrough.onFinish = { completed in finishWalkthrough(completed: completed) }
            isRunningFullAcademy = true
            // A tour cut short (the app was closed mid-tour) picks up where
            // it stopped.
            let steps = currentWalkthroughSteps()
            walkthrough.start(steps, at: appSettings.tourProgress.resumeStepID(in: steps))
            closePracticeSalonIfNoTour()
        }
    }

    /// The practice salon the tour runs in. If it can't open, the tour runs
    /// on the real salon in its explain-only form (`WalkthroughTourContext`).
    private func openPracticeSalonForTour() {
        guard let practiceSalon, !practiceSalon.isOpen else { return }
        if !practiceSalon.open() {
            Logger.contentNav.error("Practice salon unavailable; the tour explains the real salon instead.")
        }
    }

    /// Never leave the window on the practice salon without a tour in it.
    private func closePracticeSalonIfNoTour() {
        guard !walkthrough.isActive, practiceSalon?.isOpen == true else { return }
        practiceSalon?.close()
    }

    /// The tour ended: it never starts on its own again, a finished run is
    /// recorded, and the window goes back to the real salon.
    private func finishWalkthrough(completed: Bool) {
        appSettings.hasSeenAppTour = true
        if completed, isRunningFullAcademy {
            appSettings.hasCompletedAcademy = true
        }
        isRunningFullAcademy = false
        practiceSalon?.close()
        selectSurface(.dashboard, resetPath: true)
    }

    /// The Academy's "open Clients" and "open Insights" missions: the user
    /// picked the tab themselves.
    private func reportTabMission(_ item: NavigationItem) {
        switch item {
        case .clients: walkthrough.observe(.clientsTabOpened)
        case .insights: walkthrough.observe(.insightsTabOpened)
        case .dashboard, .settings: break
        }
    }

    /// Settings asks for the tour: from the start, from where it stopped, or
    /// one lesson.
    private func launchWalkthrough(_ request: WalkthroughLaunchRequest) {
        guard canStartWalkthroughInCurrentRuntime else { return }

        isExplicitWalkthroughReplayPending = true
        switch request {
        case .replayGettingStarted:
            appSettings.replayGettingStarted()
            appSettings.resetTourProgress()
        case .startOver:
            appSettings.resetTourProgress()
        case .continueTour, .lesson:
            break
        }
        walkthroughStartTask?.cancel()
        closeWalkthroughPresentationIfNeeded()
        presentedSheet = nil
        openPracticeSalonForTour()

        let steps: [WalkthroughStep]
        let startStepID: String?
        switch request {
        case .replayGettingStarted, .startOver:
            steps = currentWalkthroughSteps()
            startStepID = nil
        case .continueTour:
            steps = currentWalkthroughSteps()
            // Every lesson done: Continue replays from the start.
            startStepID = appSettings.tourProgress.resumeStepID(in: steps)
        case .lesson(let lesson):
            steps = WalkthroughController.steps(
                for: lesson,
                role: appSettings.onboardingRole,
                context: currentWalkthroughContext()
            )
            startStepID = nil
        }
        guard !steps.isEmpty else {
            Logger.contentNav.notice("Walkthrough request had no stops for this role and salon.")
            isExplicitWalkthroughReplayPending = false
            closePracticeSalonIfNoTour()
            return
        }

        selectSurface(.dashboard, resetPath: true)
        revealSplitSidebarForWalkthroughIfNeeded()

        walkthroughStartTask = Task { @MainActor in
            defer { isExplicitWalkthroughReplayPending = false }
            try? await Task.sleep(for: .milliseconds(450))
            // Cancelled by a newer start, which owns the practice salon now.
            guard !Task.isCancelled else { return }
            guard presentedSheet == nil else {
                closePracticeSalonIfNoTour()
                return
            }
            walkthrough.onFinish = { completed in finishWalkthrough(completed: completed) }
            if case .lesson = request {
                isRunningFullAcademy = false
            } else {
                isRunningFullAcademy = true
            }
            walkthrough.restart(steps, at: startStepID)
        }
    }

    /// The tour for this device's role, shaped by what the store holds right
    /// now: explain-only when real clients exist, and client-detail/checkout
    /// steps only when a sample client is there to open.
    private func currentWalkthroughSteps() -> [WalkthroughStep] {
        WalkthroughController.tour(for: appSettings.onboardingRole, context: currentWalkthroughContext())
    }

    private func currentWalkthroughContext() -> WalkthroughTourContext {
        WalkthroughTourContext.resolve(
            in: tourModelContext,
            isPINSet: appSettings.isPINSet
        )
    }

    /// The store the tour runs on: the practice salon while it is open. Read
    /// from the salon itself, not the environment, so a task started before
    /// the window switched stores still gets the right one.
    private var tourModelContext: ModelContext {
        practiceSalon?.session?.container.mainContext ?? modelContext
    }

    private var canStartWalkthroughInCurrentRuntime: Bool {
        !AppRuntime.isUITesting || AppRuntime.shouldStartWalkthroughForUITesting
    }

    private var shouldAutoStartWalkthrough: Bool {
        !appSettings.hasSeenAppTour || AppRuntime.shouldStartWalkthroughForUITesting
    }

    /// Moves the app to where the current stop lives: its screen, a root or
    /// pushed screen inside it, and the sheet it needs. Runs for every stop,
    /// so consecutive stops on one screen and replays started from another
    /// tab still land on the real target.
    private func synchronizeWalkthroughStep(_ step: WalkthroughStep?) {
        guard walkthrough.isActive, let step else {
            closeWalkthroughPresentationIfNeeded()
            return
        }

        #if os(iOS)
        // Visit Details hides the iPhone tab bar. Reveal its real navigation
        // controls before the Academy asks the user to open Insights.
        if horizontalSizeClass == .compact, step.id == WalkthroughStepID.insightsTab {
            router.popAllToRoot()
            walkthroughRoutedClientID = nil
        }
        #endif

        if let surface = step.surface {
            selectSurface(surface)
            resetRootPathForWalkthroughStepIfNeeded(step)
        }
        #if os(iOS)
        if horizontalSizeClass != .compact {
            columnVisibility = step.showsNavigation ? .all : .detailOnly
        }
        #else
        columnVisibility = step.showsNavigation ? .all : .detailOnly
        #endif

        synchronizeWalkthroughPresentation(step.presents)
        synchronizeWalkthroughClientsStack(for: step)
    }

    /// Dashboard and Insights stops point at the screen's root content, so a
    /// screen left pushed on top of it is closed. The Settings stop for the
    /// tab itself shows the Settings list. Settings sections are pushed by
    /// SettingsView for the stop that needs them, and the Clients stack is
    /// handled by `synchronizeWalkthroughClientsStack(for:)`.
    private func resetRootPathForWalkthroughStepIfNeeded(_ step: WalkthroughStep) {
        guard step.route == nil else { return }

        switch step.surface {
        case .dashboard:
            if !router.dashboardPath.isEmpty { router.popDashboardToRoot() }
        case .insights:
            if !router.insightsPath.isEmpty { router.insightsPath = NavigationPath() }
        case .settings:
            if step.anchor == .settings, !router.settingsPath.isEmpty { router.settingsPath = NavigationPath() }
        case .clients, .none:
            break
        }
    }

    private func synchronizeWalkthroughPresentation(_ presentation: WalkthroughPresentation?) {
        guard walkthrough.isActive else {
            closeWalkthroughPresentationIfNeeded()
            return
        }

        switch presentation {
        case .newClient:
            presentedSheet = .newClient
            isWalkthroughDrivingSheet = true
        case .checkout:
            break
        case .none:
            closeWalkthroughPresentationIfNeeded()
        }
    }

    private func closeWalkthroughPresentationIfNeeded() {
        guard isWalkthroughDrivingSheet else { return }
        presentedSheet = nil
        isWalkthroughDrivingSheet = false
    }

    /// Puts the Clients stack where the current stop needs it. Client-detail
    /// stops need the sample client open (with a pet, for pet stops), even
    /// after the user wandered off during a hands-on stop: whatever client
    /// is open is never trusted, because the next hands-on stop would check
    /// its pet in for real. Client-list stops need the list itself, not a
    /// profile left open by an earlier lesson.
    private func synchronizeWalkthroughClientsStack(for step: WalkthroughStep) {
        switch step.route {
        case .demoClientDetail:
            if walkthroughNeedsClientDetailNavigation(for: step) {
                openWalkthroughDemoClientDetail()
            }
        case .none:
            guard step.surface == .clients, !router.clientsPath.isEmpty else { return }
            router.popClientsToRoot()
            walkthroughRoutedClientID = nil
        }
    }

    private func walkthroughNeedsClientDetailNavigation(for step: WalkthroughStep) -> Bool {
        // The client-list mission: the user opened the tour client's card
        // themselves. Keep that screen rather than pushing it a second time.
        if walkthroughRoutedClientID == nil,
           let tourClient = SampleData.tourClient(in: tourModelContext),
           isShowingOnlyWalkthroughClient(tourClient.persistentModelID) {
            walkthroughRoutedClientID = tourClient.persistentModelID
        }
        guard let routedID = walkthroughRoutedClientID,
              isShowingOnlyWalkthroughClient(routedID),
              let client = tourModelContext.model(for: routedID) as? Client,
              SampleData.isSample(client)
        else { return true }
        return step.needsTourPet && (client.pets ?? []).isEmpty
    }

    /// The Clients stack holds exactly the profile the tour opened. A count
    /// alone isn't enough: a user who went back and opened a real client
    /// also leaves one screen on the stack.
    private func isShowingOnlyWalkthroughClient(_ clientID: PersistentIdentifier) -> Bool {
        router.clientsPath == NavigationPath([AppDestination.clientDetail(clientID)])
    }

    private func openWalkthroughDemoClientDetail() {
        // The route value (.demoClientDetail) is identical across the
        // client-detail stops, so `onChange(of: currentStep?.route)` fires this once (the first)
        // — the same cycle the New Client sheet dismisses. On iPhone the push
        // lands fine. On iPad / macOS a navigation issued into the split-view
        // detail column while a cover dismisses is silently dropped, so the
        // client-detail tour steps never opened the profile. Defer the push past
        // the dismissal there so it takes.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard walkthrough.isActive,
                  let step = walkthrough.currentStep,
                  step.route == .demoClientDetail,
                  walkthroughNeedsClientDetailNavigation(for: step)
            else { return }
            performDemoClientDetailNavigation()
        }
    }

    private func performDemoClientDetailNavigation() {
        // Only a sample client (fixed UUID) is ever opened. A client created
        // during the tour, or any other real client, is never the target: the
        // hands-on steps that follow would check its pet in for real.
        guard let client = SampleData.tourClient(in: tourModelContext) else {
            Logger.contentNav.info("Walkthrough client-detail route skipped: no sample client in the store.")
            return
        }
        selectClientsSurface()
        guard !(walkthroughRoutedClientID == client.persistentModelID && isShowingOnlyWalkthroughClient(client.persistentModelID)) else { return }
        router.popClientsToRoot()
        router.navigateToClient(client)
        walkthroughRoutedClientID = client.persistentModelID
    }

    private func continueWalkthroughAfterClientCreate(_ notification: Notification) {
        guard walkthrough.isActive,
              walkthrough.currentStep?.presents == .newClient,
              notification.clientCreatePhase == .created,
              let clientID = notification.createdClientID
        else { return }

        walkthrough.focusClientDetail(clientID)
        selectClientsSurface()
        router.popClientsToRoot()
        revealSplitSidebarForWalkthroughIfNeeded()
        presentedSheet = nil
        isWalkthroughDrivingSheet = false

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard walkthrough.isActive,
                  walkthrough.currentStep?.presents == .newClient
            else { return }
            walkthrough.completePresentation(.newClient)
        }
    }

    private enum NavigationType { case pet, client }

    private func handleNavigation(_ notification: Notification, type: NavigationType) {
        guard let uuid = notification.userInfo?["uuid"] as? UUID else { return }

        // Dedupe near-simultaneous fires (e.g. `.onReceive` + `consumePendingNavigation`
        // on cold launch). 1.5s window is generous; legitimate re-navigation by user
        // tap will exceed this trivially.
        let dedupeKey = "\(type)-\(uuid)"
        let now = Date()
        if dedupeKey == lastNavigationDedupeKey, now.timeIntervalSince(lastNavigationDedupeAt) < 1.5 {
            return
        }

        // Resolve the UUID off the main thread. These fetches fire on cold launch alongside
        // Store warmup, and the original fetch path could perceptibly stall the first
        // frame. Background context + PersistentIdentifier hand-off matches the pattern
        // used in ClientDetailViewModel.fetchVisitsAsync and DashboardViewModel.fetchChecklistStatus.
        let container = modelContext.container
        Task { @MainActor in
            let resolvedID: PersistentIdentifier? = await Task.detached(priority: .userInitiated) {
                let bgCtx = ModelContext(container)
                switch type {
                case .client:
                    var d = FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == uuid })
                    d.fetchLimit = 1
                    do {
                        return try bgCtx.fetch(d).first?.persistentModelID
                    } catch {
                        Logger.contentNav.error("Client navigation fetch failed: \(String(describing: error))")
                        return nil
                    }
                case .pet:
                    var d = FetchDescriptor<Pet>(predicate: #Predicate { $0.uuid == uuid })
                    d.fetchLimit = 1
                    do {
                        return try bgCtx.fetch(d).first?.persistentModelID
                    } catch {
                        Logger.contentNav.error("Pet navigation fetch failed: \(String(describing: error))")
                        return nil
                    }
                }
            }.value

            guard let id = resolvedID else { return }

            switch type {
            case .client:
                guard let client = modelContext.model(for: id) as? Client else { return }
                selectClientsSurface()
                router.popClientsToRoot()
                router.navigateToClient(client)
            case .pet:
                guard let pet = modelContext.model(for: id) as? Pet, let owner = pet.owner else { return }
                selectClientsSurface()
                router.popClientsToRoot()
                router.navigateToClient(owner)
                router.navigateToPet(pet)
            }
            lastNavigationDedupeKey = dedupeKey
            lastNavigationDedupeAt = now
            clearPendingNavigation(kind: type == .client ? .client : .pet, uuid: uuid)
        }
    }

    private func handleNavigationSelection(_ notification: Notification) {
        if notification.userInfo?[NavigationSelectionKey.item.rawValue] as? String == "recenthistory" {
            selectSurface(.dashboard, resetPath: notification.shouldResetNavigationPath)
            presentedSheet = .recentHistory(nil)
            return
        }
        guard let item = notification.requestedNavigationItem else { return }
        selectSurface(item, resetPath: notification.shouldResetNavigationPath)
        // After the surface switch, which resets the Settings path.
        if item == .settings, let section = notification.requestedSettingsSection {
            router.openSettingsSection(section)
        }
    }

    private func selectClientsSurface() {
        selectSurface(.clients)
    }

    private func selectSurface(_ item: NavigationItem, resetPath: Bool = false) {
        sidebarSelection = item
        tabSelection = item
        router.activeNavigationItem = item
        if resetPath {
            router.popToRoot()
        }
    }

    private func revealSplitSidebarForWalkthroughIfNeeded() {
        #if os(iOS)
        guard horizontalSizeClass != .compact else { return }
        #endif
        guard columnVisibility != .all else { return }
        columnVisibility = .all
    }

    private func consumePendingNewClientRequest() {
        guard UserDefaults.standard.string(forKey: AppMenuCommand.pendingNewClientRequestKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: AppMenuCommand.pendingNewClientRequestKey)
        presentedSheet = .newClient
    }

    private func applyUITestLaunchOverrides() {
        guard let rawValue = AppRuntime.uiTestingStartTab else { return }

        if rawValue == "recenthistory" {
            selectSurface(.dashboard, resetPath: true)
            presentedSheet = .recentHistory(nil)
            return
        }

        guard let item = NavigationItem(rawValue: rawValue) else { return }

        selectSurface(item, resetPath: true)
    }

    private func consumePendingNavigation() {
        guard let kindRaw = UserDefaults.standard.string(forKey: PendingNavigationCommand.kindKey),
              let kind = PendingNavigationCommand.Kind(rawValue: kindRaw),
              let uuidRaw = UserDefaults.standard.string(forKey: PendingNavigationCommand.uuidKey),
              let uuid = UUID(uuidString: uuidRaw) else { return }

        let type: NavigationType = kind == .pet ? .pet : .client
        handleNavigation(Notification(name: .navigateToClient, object: nil, userInfo: ["uuid": uuid]), type: type)
    }

    private func clearPendingNavigation(kind: PendingNavigationCommand.Kind, uuid: UUID) {
        guard UserDefaults.standard.string(forKey: PendingNavigationCommand.kindKey) == kind.rawValue,
              UserDefaults.standard.string(forKey: PendingNavigationCommand.uuidKey) == uuid.uuidString else { return }
        UserDefaults.standard.removeObject(forKey: PendingNavigationCommand.kindKey)
        UserDefaults.standard.removeObject(forKey: PendingNavigationCommand.uuidKey)
    }

    // MARK: - Views

    @ViewBuilder
    private var rootContent: some View {
        Group {
            #if os(macOS)
            splitView
            #else
            if usesCompactTabNavigation {
                tabView
            } else {
                splitView
            }
            #endif
        }
        .preferredColorScheme(appSettings.preferredColorScheme.swiftUIScheme)
    }

    private var tabView: some View {
        TabView(selection: tabSelectionBinding) {
            NavigationStack(path: $router.dashboardPath) {
                DashboardView(namespace: sharedNamespace)
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
            .tabItem { Label(NSLocalizedString("dashboard.title", value: "Dashboard", comment: ""), systemImage: "square.grid.2x2.fill") }
            .tag(NavigationItem.dashboard)

            NavigationStack(path: $router.clientsPath) {
                ClientsView(namespace: sharedNamespace)
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
            .tabItem { Label(NSLocalizedString("clients.tab", value: "Clients", comment: ""), systemImage: "person.3.fill") }
            .tag(NavigationItem.clients)

            NavigationStack(path: $router.insightsPath) {
                InsightsView()
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
            .accessibilityIdentifier("tab.content.insights")
            .tabItem { Label(NSLocalizedString("insights.tab", value: "Insights", comment: ""), systemImage: "chart.bar.fill") }
            .tag(NavigationItem.insights)

            NavigationStack(path: $router.settingsPath) {
                SettingsView()
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
            .tabItem { Label(NSLocalizedString("settings.tab", value: "Settings", comment: ""), systemImage: "gear") }
            .tag(NavigationItem.settings)
        }
        .tint(.primary)
        .accessibilityIdentifier("content.tabView")
        // Invisible anchor cells aligned to the real tab bar so the walkthrough
        // can spotlight tab items precisely (SwiftUI doesn't expose `.tabItem`
        // frames). Bottom-aligned and safe-area-respecting → lands on the icons,
        // resolved through the same `proxy[anchor]` path as the macOS sidebar.
        .overlay(alignment: .bottom) { tabBarAnchorStrip }
    }

    /// One clear, evenly-spaced cell per tab, matching the tab bar's layout, each
    /// registered as a walkthrough anchor. Non-interactive so taps pass through.
    private var tabBarAnchorStrip: some View {
        HStack(spacing: 0) {
            ForEach(NavigationItem.allCases) { item in
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .walkthroughAnchor(item.walkthroughAnchorID)
            }
        }
        .frame(height: 49)
        // The Academy's first stop points at the whole tab bar.
        .walkthroughAnchor(.appNavigation)
        .allowsHitTesting(false)
    }

    /// The root overlay owns every step on iPhone (single coordinate space), but
    /// only the sidebar nav rows on a `NavigationSplitView` (iPad regular / Mac) —
    /// content steps are handled by the detail-column overlay so they frame tightly.
    private var rootOverlayScope: WalkthroughOverlayScope {
        #if os(macOS)
        return .navigation
        #else
        return usesCompactTabNavigation ? .all : .navigation
        #endif
    }

    #if os(iOS)
    private var usesCompactTabNavigation: Bool {
        horizontalSizeClass == .compact && UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif

    private var splitView: some View {
        #if os(macOS)
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: sidebarSelectionBinding) { item in
                selectSurface(item, resetPath: true)
            }
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } detail: {
            // Content-step overlay hosted INSIDE the detail column so its anchors
            // resolve in the detail's coordinate space (a root overlay drops the
            // sidebar offset and the spotlight spans the whole window).
            splitViewDetail
                .walkthroughOverlay(walkthrough, scope: .rootContent)
        }
        .background {
            MacTranslucentBackground()
                .ignoresSafeArea()
        }
        .frame(minWidth: 820, minHeight: 560)
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: sidebarSelectionBinding) { item in
                selectSurface(item, resetPath: true)
                collapseSplitSidebarAfterSelectionIfNeeded()
            }
        } detail: {
            // Content-step overlay hosted inside the detail column (see macOS note).
            splitViewDetail
                .walkthroughOverlay(walkthrough, scope: .rootContent)
        }
        #endif
    }

    @ViewBuilder
    private var splitViewDetail: some View {
        switch sidebarSelection {
        case .dashboard:
            NavigationStack(path: $router.dashboardPath) {
                DashboardView(namespace: sharedNamespace)
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
        case .clients:
            NavigationStack(path: $router.clientsPath) {
                ClientsView(namespace: sharedNamespace)
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
        case .insights:
            NavigationStack(path: $router.insightsPath) {
                InsightsView()
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
        case .settings:
            NavigationStack(path: $router.settingsPath) {
                SettingsView()
                    .navigationDestination(for: AppDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
        case .none:
            Text(NSLocalizedString("content.select_item", value: "Select an item", comment: ""))
        }
    }

    // MARK: - Navigation Destination Factory

    @ViewBuilder
    private func destinationView(for destination: AppDestination) -> some View {
        switch destination {
        case .clientDetail(let id):
            if let client = modelContext.model(for: id) as? Client {
                ClientDetailView(client: client, namespace: sharedNamespace)
            } else {
                missingDestinationView
            }

        case .clientLoyalty(let id):
            if let client = modelContext.model(for: id) as? Client {
                ClientLoyaltyView(client: client)
            } else {
                missingDestinationView
            }

        case .petDetail(let id):
            if let pet = modelContext.model(for: id) as? Pet {
                PetDetailView(pet: pet, namespace: sharedNamespace)
            } else {
                missingDestinationView
            }

        case .visitDetail(let id):
            if let visit = modelContext.model(for: id) as? Visit {
                VisitDetailView(visit: visit)
            } else {
                missingDestinationView
            }

        case .petHistory(let id):
            if let pet = modelContext.model(for: id) as? Pet {
                PetHistoryView(pet: pet, wrapsInNavigationStack: false)
            } else {
                missingDestinationView
            }

        case .checkout(let petID, let visitID, let allowsCompletedPreferredVisit):
            if let pet = modelContext.model(for: petID) as? Pet {
                if let activeVisitID = try? CheckoutRouteResolver.activeVisitID(
                    for: petID,
                    preferredVisitID: visitID,
                    allowsCompletedPreferredVisit: allowsCompletedPreferredVisit,
                    dataStore: dataStore
                ), let visit = modelContext.model(for: activeVisitID) as? Visit {
                    CheckoutView(pet: pet, visit: visit)
                } else {
                    noActiveSessionView
                }
            } else {
                missingDestinationView
            }
        }
    }

    private var noActiveSessionView: some View {
        ContentUnavailableView(
            NSLocalizedString("checkout.no_active_session_title", value: "No Active Session", comment: ""),
            systemImage: "clock.badge.xmark",
            description: Text(NSLocalizedString(
                "checkout.no_active_session_message",
                value: "This pet is not checked in right now. Start a visit before opening checkout.",
                comment: ""
            ))
        )
    }

    private var missingDestinationView: some View {
        ContentUnavailableView(
            NSLocalizedString("content.missing_record_title", value: "Record Unavailable", comment: ""),
            systemImage: "exclamationmark.triangle.fill",
            description: Text(NSLocalizedString(
                "content.missing_record_message",
                value: "This record may have been deleted. Return to the list and try again.",
                comment: ""
            ))
        )
    }
}

private extension Logger {
    static let contentNav = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "ContentNavigation")
}

private extension ContentView {
    func collapseSplitSidebarAfterSelectionIfNeeded() {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        guard columnVisibility != .doubleColumn else { return }
        withAnimation(MotionSystem.snappy) {
            columnVisibility = .detailOnly
        }
        #endif
    }
}

private extension View {
    /// Re-hosts the walkthrough content overlay on a *pushed* detail view.
    ///
    /// On iPad / macOS the content overlay normally lives on the split-view's
    /// `detail` column (`splitViewDetail`), which sits OUTSIDE the column's
    /// `NavigationStack`. Anchors set inside a *pushed* destination (e.g.
    /// `ClientDetailView`'s `.cdOwner`) don't propagate across that boundary, so
    /// the spotlight had nothing to draw and the bubble vanished the moment the
    /// client-detail tour steps opened the profile. Hosting the overlay on the
    /// pushed view itself puts it in the same layer as those anchors.
    ///
    /// iPhone (compact) keeps its single root `.all` overlay, which already
    /// captures pushed anchors — so this is a deliberate no-op there to avoid a
    /// double-dim.
    @ViewBuilder
    func walkthroughDetailOverlayIfNeeded(
        _ controller: WalkthroughController,
        sizeClass: UserInterfaceSizeClass?
    ) -> some View {
        if sizeClass == .compact {
            self
        } else {
            walkthroughOverlay(controller, scope: .detailContent)
        }
    }
}
