//
//  RootView.swift
//  Pawtrackr
//
//  App shell: PIN gate + main tabs
//

import SwiftUI
import SwiftData
import OSLog

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthenticationViewModel.self) private var authViewModel
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(DataStoreService.self) private var dataStore: DataStoreService?
    @Query private var businessConfigs: [BusinessConfig]
    /// The Academy's sandbox. While it is open the main window runs on it.
    @State private var practiceSalon = PracticeSalon()
    @State private var showOnboarding = false
    @State private var didEvaluateOnboarding = false
    @State private var didRunStartupMaintenance = false
    @State private var bypassLockForCurrentSession = false
    @State private var showPrivacyScreen = false
    @State private var showWhatIsNew = false
    @State private var didDismissLaunchSubscriptionPaywall = false
    @State private var storeRestoreRequest: StoreRestoreRequest?
    @State private var restoreResultMessage: String?

    var body: some View {
        ZStack {
            Group {
                if shouldBypassLockGate {
                    mainShell
                } else {
                    PinLockGate(onUnlock: {
                        authViewModel.signInAfterUnlock()
                    }) {
                        mainShell
                    }
                }
            }

            if shouldShowLaunchSubscriptionPaywall {
                SubscriptionPaywallView(
                    allowsDismiss: true,
                    onDismiss: dismissLaunchSubscriptionPaywall
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(20)
            }
            
            if showPrivacyScreen {
                PrivacyScreen()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldShowLaunchSubscriptionPaywall)
        .sheet(isPresented: Binding(
            get: { showWhatIsNew && !shouldShowLaunchSubscriptionPaywall },
            set: { presented in
                if !presented {
                    showWhatIsNew = false
                }
            }
        )) {
            WhatIsNewView {
                acknowledgeWhatIsNew()
            }
        }
        .sheet(item: $storeRestoreRequest) { request in
            StoreRestoreView(currentClientCount: request.currentClientCount)
        }
        .alert(
            AppLocalization.localized("store_restore.result.title", value: "Restore"),
            isPresented: Binding(
                get: { restoreResultMessage != nil },
                set: { if !$0 { restoreResultMessage = nil } }
            )
        ) {
            Button(AppLocalization.localized("common.ok", value: "OK"), role: .cancel) {
                // Held back while the result alert was up; SwiftUI presents one at a time.
                evaluateWhatIsNew()
            }
        } message: {
            Text(restoreResultMessage ?? "")
        }
        .adaptiveCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
                bypassLockForCurrentSession = true
                authViewModel.signInAfterUnlock()
            }
            .interactiveDismissDisabled(true)
        }
        .task {
            consumeRestoreResult()
            if restoreResultMessage == nil {
                evaluateWhatIsNew()
            }
            evaluateOnboardingIfReady()
            runStartupMaintenanceIfReady()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            Logger.ui.debug("ScenePhase changed from \(String(describing: oldPhase)) to \(String(describing: newPhase))")
            switch newPhase {
            case .active:
                TimeHub.shared.resume()
                withAnimation {
                    showPrivacyScreen = false
                }
                // Re-resolve the entitlement on every foreground: StoreKit emits
                // no Transaction.update when a cancelled subscription simply
                // lapses, so this is what catches "expired while backgrounded".
                Task { await entitlements.refresh() }
            case .inactive:
                showPrivacyScreen = PrivacyScreenScenePolicy.shouldCoverContent(for: newPhase)
            case .background:
                TimeHub.shared.pause()
                bypassLockForCurrentSession = false
                showPrivacyScreen = PrivacyScreenScenePolicy.shouldCoverContent(for: newPhase)
            @unknown default:
                break
            }
        }
        .onChange(of: shouldShowLaunchSubscriptionPaywall) { _, locked in
            if locked {
                showWhatIsNew = false
            }
        }
        .onChange(of: onboardingIncomplete) { _, incomplete in
            // Adopt a completed local setup if it changes while Welcome is open.
            if !incomplete, showOnboarding {
                showOnboarding = false
            }
        }
    }

    private var mainShell: some View {
        VStack(spacing: 0) {
            // Always about the real store, so it sits outside the practice salon.
            DataSafetyBannerHost(onReviewRestore: presentStoreRestore)
            if practiceSalon.isOpen {
                PracticeSalonBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // The same modifiers in both cases, only their values change, so
            // ContentView (and the tour it runs) keeps its identity when the
            // window switches between the real store and the practice salon.
            ContentView()
                .modelContainer(practiceSalon.session?.container ?? modelContext.container)
                .environment(practiceSalon.session?.dataStore ?? dataStore)
                .environment(practiceSalon)
                .environment(\.isPracticeSalon, practiceSalon.isOpen)
        }
        .animation(.easeInOut(duration: 0.25), value: practiceSalon.isOpen)
    }

    private func evaluateWhatIsNew() {
        guard !AppRuntime.isUITesting else { return }
        // Hold this back during onboarding so it doesn't race the cover —
        // SwiftUI only presents one sheet/cover at a time per stack.
        guard !onboardingIncomplete, !showOnboarding else { return }
        guard !shouldShowLaunchSubscriptionPaywall else { return }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let lastSeenVersion = UserDefaults.standard.string(forKey: "lastSeenVersion")
        if currentVersion != lastSeenVersion {
            showWhatIsNew = true
        }
    }

    private func acknowledgeWhatIsNew() {
        showWhatIsNew = false
        UserDefaults.standard.set(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, forKey: "lastSeenVersion")
    }

    private func evaluateOnboardingIfReady() {
        guard !didEvaluateOnboarding else { return }
        didEvaluateOnboarding = true
        if !businessConfigs.contains(where: \.isSetupComplete) {
            showOnboarding = true
        }
    }

    private func runStartupMaintenanceIfReady() {
        guard !didRunStartupMaintenance else { return }
        didRunStartupMaintenance = true
        guard !AppRuntime.isUITesting else { return }

        let container = modelContext.container
        Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)
            DataMigrations.coercePets(in: backgroundContext)
            DataMigrations.backfillVisitSessionTokens(in: backgroundContext)
            DataMigrations.ensureServiceCatalog(in: backgroundContext)
            DataMigrations.ensureMessageTemplates(in: backgroundContext)
            DataMigrations.ensureLoyaltyDefaults(in: backgroundContext)
            do {
                try await LoyaltyService(modelContainer: container).ensureDefaults()
            } catch {
                Logger.database.error("Starter reward reconciliation failed: \(error.localizedDescription)")
            }
            DataMigrations.backfillLoyaltyLedger(in: backgroundContext)
            SummaryUpdater.rebuildAllSummaries(in: backgroundContext)
            DataSafetyMonitor.evaluateClientStoreState(in: backgroundContext)
            // Reconcile the local index and respect App Lock before indexing.
            await SpotlightIndexer.shared.reconcileAtLaunch(container: container)
        }
    }

    private func presentStoreRestore() {
        let clientCount = (try? modelContext.fetchCount(FetchDescriptor<Client>())) ?? 0
        storeRestoreRequest = StoreRestoreRequest(currentClientCount: clientCount)
    }

    /// A restore scheduled last session ran in PawtrackrApp.init, before this
    /// view existed; tell the user how it went, once.
    private func consumeRestoreResult() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: StoreBackupRestore.lastRestoreFailureKey) {
            defaults.removeObject(forKey: StoreBackupRestore.lastRestoreFailureKey)
            switch StoreBackupRestore.FailureReason(rawValue: raw) ?? .failed {
            case .expired:
                restoreResultMessage = AppLocalization.localized(
                    "store_restore.result.expired",
                    value: "The restore you started earlier wasn't finished, so nothing was changed. Start it again from Restore Clients and reopen Pawtrackr right away."
                )
            case .unopenable:
                restoreResultMessage = AppLocalization.localized(
                    "store_restore.result.unopenable",
                    value: "That backup couldn't be opened, so Pawtrackr put your previous data back. Nothing was lost."
                )
            case .failed:
                restoreResultMessage = AppLocalization.localized(
                    "store_restore.result.failed",
                    value: "Pawtrackr couldn't restore the backup, and nothing was changed."
                )
            }
        } else if defaults.object(forKey: StoreBackupRestore.lastRestoredClientCountKey) != nil {
            let count = defaults.integer(forKey: StoreBackupRestore.lastRestoredClientCountKey)
            defaults.removeObject(forKey: StoreBackupRestore.lastRestoredClientCountKey)
            restoreResultMessage = String(
                format: AppLocalization.localized(
                    "store_restore.result.restored_kept_fmt",
                    value: "Restored %d clients from the backup on this device. What was here before is kept as “Before your last restore” in Restore Clients."
                ),
                count
            )
        }
    }

    private func dismissLaunchSubscriptionPaywall() {
        didDismissLaunchSubscriptionPaywall = true
        evaluateWhatIsNew()
    }

    private var onboardingIncomplete: Bool {
        !businessConfigs.contains(where: \.isSetupComplete)
    }

    private var shouldShowLaunchSubscriptionPaywall: Bool {
        entitlements.status == .notEntitled
            && !onboardingIncomplete
            && !showOnboarding
            && !didDismissLaunchSubscriptionPaywall
    }

    private var shouldBypassLockGate: Bool {
        onboardingIncomplete || showOnboarding || bypassLockForCurrentSession
    }
}

/// Identifies one presentation of the restore sheet with the live client count
/// captured at tap time.
private struct StoreRestoreRequest: Identifiable {
    let id = UUID()
    let currentClientCount: Int
}

/// Owns the data-safety @AppStorage reads so a UserDefaults write re-renders
/// only this banner. When RootView held them, every write rebuilt the whole
/// shell and the onboarding cover. A view model that wrote its draft while
/// being built could otherwise loop forever on a blank screen.
private struct DataSafetyBannerHost: View {
    let onReviewRestore: () -> Void

    @AppStorage(DataSafetyMonitor.suspectedDataLossKey) private var dataLossSuspected = false
    @AppStorage(DataSafetyMonitor.suspectedDataLossMessageKey) private var dataLossMessage = ""
    @AppStorage(StoreBackupRestore.offerDirectoryKey) private var restoreOfferDirectory = ""
    @AppStorage(StoreBackupRestore.offerClientCountKey) private var restoreOfferClientCount = 0
    @AppStorage(StoreBackupRestore.scheduledRestoreKey) private var scheduledRestoreDirectory = ""
    /// Dismissing the empty-store warning only hides it for this session: the
    /// evidence (and the Start Fresh lock) must survive a stray tap.
    @State private var dataLossBannerHiddenThisSession = false

    var body: some View {
        DataSafetyBanner(
            isRestorePending: !scheduledRestoreDirectory.isEmpty,
            isDataLossSuspected: dataLossSuspected && !dataLossBannerHiddenThisSession,
            message: dataLossMessage,
            restoreOfferClientCount: restoreOfferDirectory.isEmpty ? 0 : restoreOfferClientCount,
            onReviewRestore: onReviewRestore,
            onCancelPendingRestore: { StoreBackupRestore.cancelScheduledRestore() },
            onDismiss: dismiss
        )
    }

    private func dismiss() {
        withAnimation {
            if !restoreOfferDirectory.isEmpty {
                StoreBackupRestore.dismissOffer(directoryName: restoreOfferDirectory)
            } else {
                dataLossBannerHiddenThisSession = true
            }
        }
    }
}
