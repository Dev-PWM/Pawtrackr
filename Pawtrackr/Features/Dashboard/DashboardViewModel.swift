//
//  DashboardViewModel.swift
//  Pawtrackr
//

import Foundation
import SwiftData
import OSLog
import Combine
import SwiftUI

private let dashboardLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "Dashboard")

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Observable
@MainActor
final class DashboardViewModel {

    enum State: Equatable {
        case loading
        case loaded
        case error(String)
    }

    struct KPI: Sendable {
        var inProgressCount: Int = 0
        var revenueToday: Decimal = .zero
        var revenueYesterday: Decimal = .zero
        var completedToday: Int = 0

        @MainActor var revenueTodayString: String { revenueToday.moneyString }

        var revenueTrend: Double? {
            guard revenueYesterday > 0 else { return nil }
            let today    = (revenueToday    as NSDecimalNumber).doubleValue
            let yesterday = (revenueYesterday as NSDecimalNumber).doubleValue
            return (today - yesterday) / yesterday
        }
    }

    struct RevenuePoint: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let amount: Decimal
        var amountDouble: Double { (amount as NSDecimalNumber).doubleValue }
    }

    /// Where a Getting Started row jumps when tapped. The view owns the actual
    /// navigation (sheets / tab switches); the view model only declares intent so
    /// it stays free of SwiftUI view state. One row per action, so the action
    /// is also the row's identity.
    ///
    /// There is no service-prices row: no screen in the app sets a service's
    /// price (only sample data does), so a real salon could never finish it.
    enum ChecklistAction: String, Hashable, Sendable, CaseIterable {
        case branding      // Settings > Business
        case addClient     // The New Client sheet
        case firstVisit    // The client list, where a check-in starts

        /// The Settings section the row opens, when it opens one.
        var settingsSection: SettingSection? {
            switch self {
            case .branding: return .business
            case .addClient, .firstVisit: return nil
            }
        }
    }

    struct ChecklistItem: Identifiable, Equatable, Sendable {
        var id: ChecklistAction { action }
        let title: String
        let isCompleted: Bool
        let action: ChecklistAction
    }

    /// What the store says about setup, read off the main actor. Sample
    /// clients (fixed UUIDs, `SampleData`) and their visits never count as
    /// the salon's own.
    struct ChecklistFacts: Equatable, Sendable {
        var hasBrandingDetails = false
        var realClientCount = 0
        var realVisitCount = 0
        var sampleClientCount = 0

        static func load(in context: ModelContext) throws -> ChecklistFacts {
            let configs = try context.fetch(FetchDescriptor<BusinessConfig>())
            return ChecklistFacts(
                hasBrandingDetails: configs.contains(where: \.hasBrandingDetails),
                realClientCount: try SampleData.realClientCount(in: context),
                realVisitCount: try SampleData.realVisitCount(in: context),
                sampleClientCount: try SampleData.sampleClientCount(in: context)
            )
        }
    }

    // MARK: - Observable state
    var state: State = .loading
    var kpi = KPI()
    var activeVisits: [Visit] = []
    var recentClients: [Client] = []
    var overduePets: [Pet] = []
    var revenueSeries: [RevenuePoint] = []
    /// nil until the first checklist read finishes.
    var checklistFacts: ChecklistFacts?
    /// The Getting Started rows, based on the local store. Empty until read.
    var checklist: [ChecklistItem] {
        guard let checklistFacts else { return [] }
        return Self.checklistItems(facts: checklistFacts)
    }
    /// Every local setup row is done. The dashboard then retires the card.
    var isChecklistComplete: Bool {
        Self.isComplete(checklist)
    }
    /// Sample clients (fixed UUIDs, `SampleData`) are in the store. The
    /// checklist offers to remove them only while this is true.
    var hasSampleData = false
    var smartSuggestions: [SmartSuggestion] = []
    var appError: AppError? = nil

    // MARK: - Private
    private var isRefreshing = false
    private let repository: DashboardRepositoryProtocol
    private let predictiveActor: PredictiveSchedulingActor
    private let revenueWindowDays = 7
    private let recentClientLimit = 5
    private let overduePetLimit  = 5

    private var dataStore: DataStoreService
    private var eventBus: GlobalEventBus
    private var observers: [AnyCancellable] = []
    @ObservationIgnored private let observationLifetime = EventObservationLifetime()
    // Set (not array) so the per-refresh `contains` filters stay O(1) and don't
    // degrade as completed-visit history grows during a long session. Not pruned:
    // an entry must persist as long as the store can still return that visit as
    // active, otherwise a completed visit could momentarily reappear as active.
    private var completedVisitIDs: Set<PersistentIdentifier> = []

    init(
        dataStore: DataStoreService,
        eventBus: GlobalEventBus,
        repository: DashboardRepositoryProtocol? = nil
    ) {
        dashboardLog.info("DashboardViewModel: Initialized")
        self.dataStore = dataStore
        self.eventBus = eventBus
        self.repository = repository ?? DashboardRepository(modelContext: dataStore.container.mainContext)
        self.predictiveActor = PredictiveSchedulingActor(modelContainer: dataStore.container)

        setupObservers()
        
        Task { [weak self] in await self?.refresh() }
    }

    private func setupObservers() {
        dashboardLog.info("DashboardViewModel: Setting up observers...")
        // EventBus Stream
        let stream = eventBus.stream
        observationLifetime.task = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .checkoutCompleted(let completion):
                    self.markVisitCompleted(completion.visitID)
                    await self.refresh()
                case .storeCommitted, .refreshRequired, .clientCreated, .dataStoreReset:
                    await self.refresh()
                default:
                    break
                }
            }
        }

        // NotificationCenter Observers
        let notifications = [
            Notification.Name.clientDidCreate,
            Notification.Name.clientDidUpdate,
            Notification.Name.visitDidStart,
            Notification.Name.visitDidComplete,
            Notification.Name.serviceDidUpdate
        ]

        for name in notifications {
            dashboardLog.info("DashboardViewModel: Adding observer for \(name.rawValue)")
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                dashboardLog.info("DashboardViewModel: Received notification \(notif.name.rawValue)")
                let completedVisitID = notif.name == .visitDidComplete ? notif.visitID : nil
                Task { @MainActor [weak self] in
                    if let completedVisitID {
                        self?.markVisitCompleted(completedVisitID)
                    }
                    await self?.refresh()
                }
            }
            observationLifetime.notificationTokens.append(observer)
        }
    }

    // MARK: - Public
    func refresh() async {
        dashboardLog.info("DashboardViewModel: Refresh initiated.")
        guard !isRefreshing else {
            refreshPending = true
            dashboardLog.info("DashboardViewModel: Refresh already in progress, skipping.")
            return
        }
        isRefreshing = true
        
        appError = nil
        
        dashboardLog.info("DashboardViewModel: Entering TaskGroup.")

        await PerformanceMonitor.measureAsyncNoThrow(label: "Dashboard.refresh") {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { dashboardLog.info("Starting KPI fetch"); await self.fetchKPIs(); dashboardLog.info("Finished KPI fetch") }
                group.addTask { dashboardLog.info("Starting ActiveVisits fetch"); await self.fetchActiveVisits(); dashboardLog.info("Finished ActiveVisits fetch") }
                group.addTask { dashboardLog.info("Starting RecentClients fetch"); await self.fetchRecentClients(); dashboardLog.info("Finished RecentClients fetch") }
                group.addTask { dashboardLog.info("Starting OverduePets fetch"); await self.fetchOverduePets(); dashboardLog.info("Finished OverduePets fetch") }
                group.addTask { dashboardLog.info("Starting RevenueSeries fetch"); await self.buildRevenueSeries(days: self.revenueWindowDays); dashboardLog.info("Finished RevenueSeries fetch") }
                group.addTask { dashboardLog.info("Starting Checklist fetch"); await self.fetchChecklistStatus(); dashboardLog.info("Finished Checklist fetch") }
                group.addTask { dashboardLog.info("Starting Suggestions fetch"); await self.fetchSmartSuggestions(); dashboardLog.info("Finished Suggestions fetch") }
            }
        }
        
        dashboardLog.info("DashboardViewModel: Exited TaskGroup.")
        kpi.inProgressCount = activeVisits.count

        if case .loading = state {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                state = .loaded
            }
        }
        
        isRefreshing = false
        if refreshPending {
            refreshPending = false
            await refresh()
        }
        dashboardLog.info("DashboardViewModel: Refresh complete.")
    }
    private var refreshPending = false
    private func fetchChecklistStatus() async {
        // A fresh background context: the counts walk sample relationships,
        // which shouldn't touch the main context's objects.
        let container = dataStore.container
        do {
            let facts = try await Task.detached {
                try ChecklistFacts.load(in: ModelContext(container))
            }.value
            if checklistFacts != facts {
                checklistFacts = facts
            }
            let hasSamples = facts.sampleClientCount > 0
            if hasSampleData != hasSamples {
                hasSampleData = hasSamples
            }
        } catch {
            dashboardLog.error("Checklist fetch failed: \(error)")
        }
    }

    /// The Getting Started rows for what the local store holds.
    static func checklistItems(facts: ChecklistFacts) -> [ChecklistItem] {
        [
            ChecklistItem(
                title: AppLocalization.localized("checklist.branding", value: "Add Business Branding"),
                isCompleted: facts.hasBrandingDetails,
                action: .branding
            ),
            ChecklistItem(
                title: AppLocalization.localized("checklist.client", value: "Add Your First Client"),
                isCompleted: facts.realClientCount > 0,
                action: .addClient
            ),
            ChecklistItem(
                title: AppLocalization.localized("checklist.visit", value: "Start Your First Visit"),
                isCompleted: facts.realVisitCount > 0,
                action: .firstVisit
            )
        ]
    }

    /// Whether the rows are loaded and all done.
    nonisolated static func isComplete(_ items: [ChecklistItem]) -> Bool {
        !items.isEmpty && items.allSatisfy(\.isCompleted)
    }

    /// Removes only the sample clients and what belongs to them
    /// (`DataReset.removeSampleData`), then reloads the dashboard.
    func removeSampleData() async {
        do {
            try DataReset.removeSampleData(in: dataStore.container.mainContext)
        } catch {
            setDashboardError(error, source: #function)
        }
        await refresh()
    }

    func checkInPet(_ pet: Pet) async {
        do {
            let visitRepo = VisitRepository(modelContext: dataStore.container.mainContext, eventBus: eventBus)
            _ = try await visitRepo.checkIn(pet: pet, date: Date.now)
            await refresh()
        } catch {
            setDashboardError(error, source: #function)
        }
    }

    // MARK: - Private fetches

    private func fetchOverduePets() async {
        do {
            let ids = try await repository.fetchOverduePets(limit: overduePetLimit)
            overduePets = ids.compactMap { dataStore.container.mainContext.model(for: $0) as? Pet }
        } catch {
            setDashboardError(error, source: #function)
            overduePets = []
        }
    }

    private func setDashboardError(_ error: Error, source: String = #function) {
        dashboardLog.error("[\(source)] \(String(describing: error))")
        if let appError = error as? AppError {
            self.appError = appError
        } else {
            self.appError = .database(error.localizedDescription)
        }
    }

    private func fetchKPIs() async {
        do {
            let stats = try await repository.fetchKPIs()
            kpi = KPI(
                inProgressCount:   stats.inProgressCount,
                revenueToday:      stats.revenueToday,
                revenueYesterday:  stats.revenueYesterday,
                completedToday:    stats.completedToday
            )
        } catch {
            setDashboardError(error, source: #function)
            kpi = KPI()
        }
    }

    private func fetchActiveVisits() async {
        dashboardLog.info("DashboardViewModel: Fetching active visits...")
        do {
            let ids = try await repository.fetchActiveVisits()
            dashboardLog.info("DashboardViewModel: Repository returned \(ids.count) visit IDs.")

            let activeIDs = ids.filter { !completedVisitIDs.contains($0) }
            let visits = activeIDs
                .compactMap { dataStore.container.mainContext.model(for: $0) as? Visit }
                .filter { !completedVisitIDs.contains($0.persistentModelID) }
            dashboardLog.info("DashboardViewModel: Resolved \(visits.count) active visits.")
            
            activeVisits = visits
        } catch {
            setDashboardError(error, source: #function)
            activeVisits = []
        }
    }

    private func markVisitCompleted(_ visitID: PersistentIdentifier) {
        completedVisitIDs.insert(visitID)
        activeVisits.removeAll { $0.persistentModelID == visitID }
    }

    private func fetchRecentClients() async {
        do {
            let ids = try await repository.fetchRecentClients(limit: recentClientLimit)
            recentClients = ids.compactMap { dataStore.container.mainContext.model(for: $0) as? Client }
        } catch {
            setDashboardError(error, source: #function)
            recentClients = []
        }
    }

    private func buildRevenueSeries(days: Int) async {
        let cal = Calendar.current
        let end = cal.startOfDay(for: .now)
        do {
            let bucket = try await repository.fetchRevenueSeries(days: days)
            guard !Task.isCancelled else { return }
            revenueSeries = makeRevenueSeries(from: bucket, days: days, calendar: cal, end: end)
        } catch {
            setDashboardError(error, source: #function)
            revenueSeries = []
        }
    }

    private func fetchSmartSuggestions() async {
        do {
            smartSuggestions = try await predictiveActor.generateSuggestions()
        } catch {
            dashboardLog.error("fetchSmartSuggestions failed: \(error)")
        }
    }

    private func makeRevenueSeries(from bucket: [Date: Decimal], days: Int, calendar: Calendar, end: Date) -> [RevenuePoint] {
        (0..<days).map { i in
            let date = calendar.date(byAdding: .day, value: -((days - 1) - i), to: end) ?? end
            return RevenuePoint(date: date, amount: bucket[date, default: .zero])
        }
    }
}
