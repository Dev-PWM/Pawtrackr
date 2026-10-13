//
//  PawtrackrApp.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//  Updated by Assistant on 2025-09-03
//

import SwiftUI
import SwiftData
import OSLog
import CoreSpotlight
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@main
struct PawtrackrApp: App {
    static let lastInitErrorKey = AppStoreBootstrap.lastInitErrorKey
    let container: ModelContainer?
    private var scheduledTasks: ScheduledTasks?
    let dataStore: DataStoreService?
    let router = NavigationRouter()
    let eventBus = GlobalEventBus()
    private var commitBridge: LocalStoreCommitBridge?
    @State private var appSettings = AppSettings()
    @State private var authViewModel: AuthenticationViewModel
    /// StoreKit 2 entitlement layer (Pawtrackr Pro). Started with the main scene;
    /// the future paywall reads this via the environment. See ADR-0001.
    @State private var entitlements = EntitlementStore()
    @AppStorage(AppSettingsKeys.appLanguageOverride) private var appLanguageOverrideRaw = AppLanguageOverride.system.rawValue

    // Platform lifecycle hooks for maintenance and Dock re-opening.
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    @UIApplicationDelegateAdaptor(PawtrackrAppDelegate.self) private var appDelegate
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(PawtrackrAppDelegate.self) private var appDelegate
    #endif

    init() {
        // 1. Initial local variables for all properties
        let initialContainer: ModelContainer?
        let initialTasks: ScheduledTasks?
        let initialAuthVM: AuthenticationViewModel

        let isUITesting = AppRuntime.isUITesting
        let isRunningUnitTests = AppRuntime.isRunningTests && !isUITesting
        // Unit tests use the Pawtrackr app as their host. If the host opens its
        // own ModelContainer alongside the test's container, the two SwiftData
        // stores coexist in the process and the runtime can invalidate model
        // instances mid-test. Skip container creation entirely for unit tests
        // so the test owns the only container in the process.
        if isRunningUnitTests {
            initialContainer = nil
            initialTasks = nil
            initialAuthVM = AuthenticationViewModel(modelContext: nil)
            self.container = nil
            self.scheduledTasks = nil
            self._authViewModel = State(initialValue: initialAuthVM)
            self.dataStore = nil
            return
        }

        // Store-file work and the one local container
        // this process opens. App Intents share the same outcome.
        let bootstrap = AppStoreBootstrap.shared()
        let inMemory = bootstrap.isInMemory
        if let localContainer = bootstrap.container {
            if isUITesting {
                try? UITestDataSeeder.seedIfNeeded(in: localContainer.mainContext)
            }
            if !inMemory {
                // The store a Spotlight rebuild reads when App Lock is turned
                // off. The launch check itself runs with startup maintenance.
                SpotlightIndexer.shared.attach(container: localContainer)
                if bootstrap.restoredLocalBackup {
                    // Different records than the index describes: rebuild.
                    SpotlightIndexer.shared.markIndexStale()
                }
            }

            initialContainer = localContainer
            initialTasks = inMemory ? nil : ScheduledTasks(modelContainer: localContainer)
            initialAuthVM = AuthenticationViewModel(modelContext: localContainer.mainContext)
        } else {
            initialContainer = nil
            initialTasks = nil
            initialAuthVM = AuthenticationViewModel(modelContext: nil)
        }

        // 2. Assign all properties
        self.container = initialContainer
        self.scheduledTasks = initialTasks
        self._authViewModel = State(initialValue: initialAuthVM)
        if let container = initialContainer {
            self.dataStore = DataStoreService(container: container)
            self.commitBridge = LocalStoreCommitBridge(container: container, eventBus: eventBus)
        } else {
            self.dataStore = nil
        }

        // 3. Start side effects AFTER full initialization
        if initialContainer != nil {
            if !inMemory {
                initialTasks?.start()

                // Fetch remote configuration
                Task {
                    await RemoteConfigService.shared.fetchConfig()
                }

            }

            // Access UserDefaults directly to avoid using StateObject before it is installed on a view
            let symbol = UserDefaults.standard.string(forKey: "currencySymbol") ?? "$"

            Task { @MainActor in
                Formatters.updateCurrencySymbol(symbol)
            }
        }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup("Pawtrackr", id: "main") {
            mainWindowContent
                .environment(\.locale, customLocale)
        }
        .defaultSize(width: 1220, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        // Present the primary window even if the menu bar extra kept the
        // process alive after the user closed every visible window.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .newItem) {
                Button(NSLocalizedString("menu_bar.new_client", value: "New Client…", comment: "")) {
                    requestNewClientFromCommand()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(NSLocalizedString("mac.command.show_insights", value: "Show Insights", comment: "")) {
                    requestNavigationFromCommand(.insights)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button(NSLocalizedString("mac.command.find_clients", value: "Find Clients", comment: "")) {
                    requestFindClientsFromCommand()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        #else
        WindowGroup {
            mainWindowContent
                .environment(\.locale, customLocale)
        }
        #endif

        WindowGroup("Client", id: "client-window", for: DetachedClientWindowRoute.self) { route in
            if let container, let route = route.wrappedValue {
                DetachedClientWindow(route: route)
                    .environment(\.locale, customLocale)
                    .environment(appSettings)
                    .environment(authViewModel)
                    .environment(dataStore)
                    .environment(router)
                    .environment(eventBus)
                    .environment(entitlements)
                    .modelContainer(container)
                    .task { entitlements.start() }
            } else {
                ContentUnavailableView(
                    AppLocalization.localized("client.window.unavailable", value: "Client Unavailable"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .environment(\.locale, customLocale)
            }
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 680)
        #endif

        WindowGroup("Insights", id: "insights-window") {
            if let container {
                DetachedInsightsWindow()
                    .environment(\.locale, customLocale)
                    .environment(appSettings)
                    .environment(authViewModel)
                    .environment(dataStore)
                    .environment(router)
                    .environment(eventBus)
                    .environment(entitlements)
                    .modelContainer(container)
                    .task { entitlements.start() }
            } else {
                Text(AppLocalization.localized("common.database_unavailable", value: "Database unavailable"))
                    .environment(\.locale, customLocale)
            }
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 720)
        #endif

        #if os(macOS)
        Settings {
            if let container = container {
                SettingsView()
                    .environment(\.locale, customLocale)
                    .environment(appSettings)
                    .environment(authViewModel)
                    .environment(dataStore)
                    .environment(router)
                    .environment(eventBus)
                    .environment(entitlements)
                    .modelContainer(container)
                    .frame(width: 450, height: 500)
            } else {
                Text(AppLocalization.localized("common.database_unavailable", value: "Database unavailable"))
                    .environment(\.locale, customLocale)
                    .frame(width: 450, height: 500)
            }
        }

        MenuBarExtra(AppLocalization.localized("menu_bar.title", value: "Pawtrackr Pulse"), systemImage: "pawprint.circle.fill") {
            if let container = container {
                PawtrackrMenuBarExtra()
                    .environment(\.locale, customLocale)
                    .environment(dataStore)
                    .modelContainer(container)
            } else {
                Text(AppLocalization.localized("common.database_unavailable", value: "Database unavailable"))
                    .environment(\.locale, customLocale)
            }
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    @ViewBuilder
    private var mainWindowContent: some View {
        if let container = container {
            RootView()
                .environment(appSettings)
                .environment(authViewModel)
                .environment(dataStore)
                .environment(router)
                .environment(eventBus)
                .environment(entitlements)
                .modelContainer(container)
                .task { entitlements.start() }
                .onContinueUserActivity("com.pawtrackr.viewPet") { activity in
                    handleViewPetActivity(activity)
                }
                .onContinueUserActivity("com.pawtrackr.viewClient") { activity in
                    handleViewClientActivity(activity)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    handleSpotlightActivity(activity)
                }
        } else {
            DataStoreRecoveryView()
                .environment(\.locale, customLocale)
        }
    }

    private var customLocale: Locale {
        (AppLanguageOverride(rawValue: appLanguageOverrideRaw) ?? .system).locale
    }

    // MARK: - Activity Handling

    private func handleViewPetActivity(_ activity: NSUserActivity) {
        guard let petIDString = activity.userInfo?["petID"] as? String,
              let uuid = UUID(uuidString: petIDString) else { return }

        requestNavigation(to: .pet, uuid: uuid)
    }

    private func handleViewClientActivity(_ activity: NSUserActivity) {
        guard let clientIDString = activity.userInfo?["clientID"] as? String,
              let uuid = UUID(uuidString: clientIDString) else { return }

        requestNavigation(to: .client, uuid: uuid)
    }

    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let rawIdentifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let identifier = SpotlightIdentifier(rawIdentifier) else { return }

        switch identifier {
        case .client(let uuid):
            requestNavigation(to: .client, uuid: uuid)
        case .pet(let uuid):
            requestNavigation(to: .pet, uuid: uuid)
        }
    }

    private func requestNavigation(to kind: PendingNavigationCommand.Kind, uuid: UUID) {
        UserDefaults.standard.set(kind.rawValue, forKey: PendingNavigationCommand.kindKey)
        UserDefaults.standard.set(uuid.uuidString, forKey: PendingNavigationCommand.uuidKey)

        let name: Notification.Name = kind == .pet ? .navigateToPet : .navigateToClient
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["uuid": uuid])
    }

    #if os(macOS)
    private func requestNewClientFromCommand() {
        UserDefaults.standard.set(UUID().uuidString, forKey: AppMenuCommand.pendingNewClientRequestKey)
        NotificationCenter.default.post(name: .showNewClientSheet, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestNavigationFromCommand(_ item: NavigationItem) {
        NotificationCenter.default.post(name: .selectNavigationItem, object: nil, userInfo: [
            NavigationSelectionKey.item.rawValue: item.rawValue,
            NavigationSelectionKey.resetPath.rawValue: true
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestFindClientsFromCommand() {
        UserDefaults.standard.set(UUID().uuidString, forKey: AppMenuCommand.pendingClientSearchFocusKey)
        requestNavigationFromCommand(.clients)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .focusClientSearch, object: nil)
        }
    }
    #endif
}

extension Notification.Name {
    static let navigateToPet = Notification.Name("navigateToPet")
    static let navigateToClient = Notification.Name("navigateToClient")
}
