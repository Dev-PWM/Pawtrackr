//
//  NavigationRouter.swift
//  Pawtrackr
//
//  Cross-platform navigation router using SwiftUI NavigationStack.
//  Replaces UIKit-based Coordinator pattern for iOS/macOS compatibility.
//

import SwiftUI
import SwiftData
import OSLog

// MARK: - Navigation Destinations

/// Type-safe navigation destinations for the app.
enum AppDestination: Hashable, Sendable {
    case clientDetail(PersistentIdentifier)
    case clientLoyalty(PersistentIdentifier)
    case petDetail(PersistentIdentifier)
    case visitDetail(PersistentIdentifier)
    case petHistory(PersistentIdentifier)
    case checkout(
        petID: PersistentIdentifier,
        visitID: PersistentIdentifier?,
        allowsCompletedPreferredVisit: Bool
    )
}

enum PendingNavigationCommand {
    enum Kind: String {
        case client
        case pet
    }

    static let kindKey = "pendingNavigationKind"
    static let uuidKey = "pendingNavigationUUID"
}

// MARK: - NavigationRouter

/// Observable router that manages navigation state across the app.
/// Uses NavigationPath for programmatic navigation with NavigationStack.
@Observable
@MainActor
final class NavigationRouter {

    /// Navigation path for the Clients tab
    var clientsPath = NavigationPath()

    /// Navigation path for the Dashboard tab
    var dashboardPath = NavigationPath()

    /// Navigation path for the Insights tab (if needed)
    var insightsPath = NavigationPath()

    /// Navigation path for the Settings tab (if needed)
    var settingsPath = NavigationPath()

    /// The surface currently hosting user-driven navigation.
    var activeNavigationItem: NavigationItem = .dashboard

    @ObservationIgnored private var lastCardTap: [NavigationItem: ContinuousClock.Instant] = [:]

    /// macOS only: a Settings section a deep link asked for. The Mac Settings
    /// screen picks sections with its own selection, not `settingsPath`, so
    /// it selects this section when it appears and then clears it.
    var requestedSettingsSection: SettingSection?

    // MARK: - Settings deep links

    /// Opens one Settings section instead of the Settings list. Call it after
    /// switching to Settings: that switch resets `settingsPath`.
    func openSettingsSection(_ section: SettingSection) {
        #if os(macOS)
        requestedSettingsSection = section
        #else
        settingsPath = NavigationPath([section])
        #endif
    }

    // MARK: - Navigation Actions

    func navigateToClient(_ client: Client) {
        append(AppDestination.clientDetail(client.persistentModelID))
    }

    /// Debounces card taps within each tab while programmatic routes remain immediate.
    func navigateToClientFromCard(_ client: Client) {
        let now = ContinuousClock.now
        if let previous = lastCardTap[activeNavigationItem], previous.duration(to: now) < .milliseconds(350) {
            return
        }
        lastCardTap[activeNavigationItem] = now
        navigateToClient(client)
    }

    /// Opens visit rewards lazily, without creating a queried destination in the client profile.
    func navigateToClientLoyalty(_ client: Client) {
        append(AppDestination.clientLoyalty(client.persistentModelID))
    }

    func navigateToPet(_ pet: Pet) {
        append(AppDestination.petDetail(pet.persistentModelID))
    }

    func navigateToVisit(_ visit: Visit) {
        append(AppDestination.visitDetail(visit.persistentModelID))
    }

    func navigateToPetHistory(_ pet: Pet) {
        append(AppDestination.petHistory(pet.persistentModelID))
    }

    func navigateToCheckout(_ pet: Pet) {
        append(AppDestination.checkout(
            petID: pet.persistentModelID,
            visitID: nil,
            allowsCompletedPreferredVisit: false
        ))
    }

    func navigateToCheckout(_ visit: Visit) {
        guard let pet = visit.pet else {
            Logger.database.error("Cannot route checkout: visit \(visit.uuid.uuidString, privacy: .public) has no pet relationship")
            return
        }
        append(AppDestination.checkout(
            petID: pet.persistentModelID,
            visitID: visit.persistentModelID,
            allowsCompletedPreferredVisit: true
        ))
    }

    func pop() {
        switch activeNavigationItem {
        case .dashboard:
            guard !dashboardPath.isEmpty else { return }
            var path = dashboardPath
            path.removeLast()
            dashboardPath = path
        case .clients:
            guard !clientsPath.isEmpty else { return }
            var path = clientsPath
            path.removeLast()
            clientsPath = path
        case .insights:
            guard !insightsPath.isEmpty else { return }
            var path = insightsPath
            path.removeLast()
            insightsPath = path
        case .settings:
            guard !settingsPath.isEmpty else { return }
            var path = settingsPath
            path.removeLast()
            settingsPath = path
        }
    }

    func popToRoot() {
        switch activeNavigationItem {
        case .dashboard:
            dashboardPath = NavigationPath()
        case .clients:
            clientsPath = NavigationPath()
        case .insights:
            insightsPath = NavigationPath()
        case .settings:
            settingsPath = NavigationPath()
        }
    }

    /// Every tab back to its root, e.g. when the window switches between the
    /// real store and the practice salon: pushed screens hold record IDs
    /// from the store they were opened in.
    func popAllToRoot() {
        dashboardPath = NavigationPath()
        clientsPath = NavigationPath()
        insightsPath = NavigationPath()
        settingsPath = NavigationPath()
    }

    func popDashboardToRoot() {
        dashboardPath = NavigationPath()
    }

    func popClientsToRoot() {
        clientsPath = NavigationPath()
    }

    private func append(_ destination: AppDestination) {
        switch activeNavigationItem {
        case .dashboard:
            var path = dashboardPath
            path.append(destination)
            dashboardPath = path
        case .clients:
            var path = clientsPath
            path.append(destination)
            clientsPath = path
        case .insights:
            var path = insightsPath
            path.append(destination)
            insightsPath = path
        case .settings:
            var path = settingsPath
            path.append(destination)
            settingsPath = path
        }
    }
}

enum CheckoutRouteResolver {
    @MainActor
    static func activeVisitID(
        for petID: PersistentIdentifier,
        preferredVisitID: PersistentIdentifier?,
        allowsCompletedPreferredVisit: Bool = false,
        dataStore: DataStoreService
    ) throws -> PersistentIdentifier? {
        try dataStore.resolveActiveCheckoutVisitID(
            for: petID,
            preferredVisitID: preferredVisitID,
            allowsCompletedPreferredVisit: allowsCompletedPreferredVisit
        )
    }
}

// MARK: - Model Hashable Conformance

/// Make SwiftData models Hashable for use with NavigationPath.
/// Uses uuid for identity since these are reference types.

extension Client: Hashable {
    static func == (lhs: Client, rhs: Client) -> Bool {
        lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}

extension Pet: Hashable {
    static func == (lhs: Pet, rhs: Pet) -> Bool {
        lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}

extension Visit: Hashable {
    static func == (lhs: Visit, rhs: Visit) -> Bool {
        lhs.uuid == rhs.uuid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}
