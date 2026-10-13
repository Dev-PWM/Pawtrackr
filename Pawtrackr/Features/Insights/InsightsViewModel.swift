//
//  InsightsViewModel.swift
//  Pawtrackr
//

import Foundation
import Combine
import SwiftData
import Observation
import OSLog
import SwiftUI
import CoreData

@Observable
@MainActor
class InsightsViewModel {
    
    enum State: Equatable {
        case loading
        case loaded
        case error(String)
    }

    struct RevenueData: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let amount: Decimal
    }

    struct DistributionData: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let count: Int
        var revenue: Decimal = .zero
    }

    struct PaymentMethodData: Identifiable, Sendable {
        let id = UUID()
        let method: Payment.Method
        let count: Int
        let amount: Decimal
    }

    struct MonthlyGrowthData: Identifiable, Sendable {
        let id = UUID()
        let month: String
        let revenue: Decimal
        let visitCount: Int
    }

    struct RetentionData: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let value: Double
    }

    struct RevenueVisitData: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let petName: String
        let clientName: String
        let serviceSummary: String
        let total: Decimal
        let paymentMethod: String
    }

    struct ServiceProfitabilityData: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let category: String
        let count: Int
        let revenue: Decimal
        let averageTicket: Decimal
        let trendPercent: Double
    }

    // MARK: - State
    var state: State = .loading
    var revenueSeries:          [RevenueData]       = []
    var serviceDistribution:    [DistributionData]  = []
    var categoryDistribution:   [DistributionData]  = []
    var paymentMethodDistribution: [PaymentMethodData] = []
    var monthlyGrowth:          [MonthlyGrowthData] = []
    var retentionRate:          Double  = 0
    var churnRiskCount:         Int     = 0
    var retentionSeries:        [RetentionData]     = []
    var totalRevenue:           Decimal = .zero
    var averageVisitValue:      Decimal = .zero
    var totalVisitsInPeriod:    Int     = 0
    var revenuePeriodDays:      Int     = 30
    var revenueDrilldown:       [RevenueVisitData] = []
    var serviceProfitability:   [ServiceProfitabilityData] = []
    private(set) var isRefreshing  = false
    private(set) var isLoadingActionableInsights = false
    /// Becomes true once `refresh()` completes successfully at least once.
    /// Stays true across subsequent refreshes — even failing ones — because
    /// the user has already seen real data and the empty/loading skeleton
    /// should not reappear.
    private(set) var hasLoadedOnce = false

    var totalCategoryVisits: Int {
        categoryDistribution.reduce(0) { $0 + $1.count }
    }

    private let dataStore: DataStoreService
    private let eventBus: GlobalEventBus
    private var actor: InsightsActor
    @ObservationIgnored private let observationLifetime = EventObservationLifetime()
    private var revenueFetchTask: Task<Void, Never>?
    private var actionableInsightsTask: Task<Void, Never>?
    private var refreshDebounceTask: Task<Void, Never>?
    private var changeSubscriptions: Set<AnyCancellable> = []
    private var refreshPending = false

    init(dataStore: DataStoreService, eventBus: GlobalEventBus = GlobalEventBus()) {
        self.dataStore = dataStore
        self.eventBus = eventBus
        self.actor = InsightsActor(modelContainer: dataStore.container)
        for name in [Notification.Name.clientDidCreate, .clientDidUpdate, .visitDidComplete, .serviceDidUpdate] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.refresh() }
                }
                .store(in: &changeSubscriptions)
        }

        let stream = eventBus.stream
        self.observationLifetime.task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .checkoutCompleted, .storeCommitted, .clientCreated, .dataStoreReset:
                    // Checkout completion: refresh immediately so the user sees updated totals.
                    await self.refresh()
                case .refreshRequired:
                    // Local edits can fire several of these in rapid succession.
                    // Coalesce them into one refresh once the burst settles.
                    self.refreshDebounceTask?.cancel()
                    self.refreshDebounceTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(800))
                        guard let self, !Task.isCancelled else { return }
                        await self.refresh()
                    }
                default:
                    break
                }
            }
        }
    }

    deinit {
        // Task.cancel() is thread-safe.
    }

    // MARK: - Public

    func refresh() async {
        guard !isRefreshing else { refreshPending = true; return }
        isRefreshing = true
        actor = InsightsActor(modelContainer: dataStore.container)
        defer {
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                refreshDebounceTask = Task { [weak self] in await self?.refresh() }
            }
        }

        _ = await PerformanceMonitor.measureAsyncNoThrow(label: "Insights.refresh") {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.fetchRevenue() }
                group.addTask { await self.fetchMonthlyGrowth() }
                group.addTask { await self.fetchDistributions() }
                group.addTask { await self.fetchClientInsights() }
            }
        }

        if !hasLoadedOnce && revenueSeries.isEmpty && serviceDistribution.isEmpty {
            // If we have no data and nothing was loaded, it might be an error or just empty.
            // We check if an error occurred during the refresh.
            // For now, we'll just ensure the state is 'loaded' so the empty states show,
            // unless a specific fetch error was logged.
        }

        hasLoadedOnce = true
        withAnimation(.spring()) {
            state = .loaded
        }

        startActionableInsightsRefresh()
    }

    func refreshRevenue() async {
        revenueFetchTask?.cancel()
        revenueFetchTask = Task {
            await fetchRevenue()
            startActionableInsightsRefresh()
        }
        await revenueFetchTask?.value
    }

    /// The exported report: the PDF and the CSV, built from one read of the
    /// store for the selected period so both show the same numbers.
    struct ReportExports {
        let pdf: ReportDocument
        let csv: ExportDocument
    }

    func makeReportExports(businessName: String) async throws -> ReportExports {
        let facts = try await BusinessReportFacts.build(container: dataStore.container, periodDays: revenuePeriodDays)
        let document = BusinessReportService.makeDocument(facts: facts, businessName: businessName)
        async let pdfData = BusinessReportService.renderAsync(document)
        let csv = await Task.detached(priority: .userInitiated) {
            BusinessReportCSV.make(facts: facts)
        }.value
        return ReportExports(pdf: ReportDocument(pdfData: await pdfData, filename: document.filename), csv: csv)
    }

    // MARK: - Actor Delegations

    private func fetchRevenue() async {
        do {
            let result = try await actor.fetchRevenue(periodDays: revenuePeriodDays)
            revenueSeries = result.series
            totalRevenue = result.totalRevenue
            totalVisitsInPeriod = result.totalVisits
            averageVisitValue = result.averageVisitValue
        } catch {
            Logger.insights.error("fetchRevenue failed: \(error)")
        }
    }

    private func fetchDistributions() async {
        do {
            let result = try await actor.fetchDistributions()
            serviceDistribution = result.services
            categoryDistribution = result.categories
            paymentMethodDistribution = result.payments
        } catch {
            Logger.insights.error("fetchDistributions failed: \(error)")
        }
    }

    private func fetchClientInsights() async {
        do {
            let result = try await actor.fetchClientInsights()
            retentionRate = result.retentionRate
            churnRiskCount = result.churnRiskCount
            retentionSeries = result.retentionSeries
        } catch {
            Logger.insights.error("fetchClientInsights failed: \(error)")
        }
    }

    private func fetchMonthlyGrowth() async {
        do {
            monthlyGrowth = try await actor.fetchMonthlyGrowth()
        } catch {
            Logger.insights.error("fetchMonthlyGrowth failed: \(error)")
        }
    }

    private func fetchActionableInsights() async {
        let requestedPeriodDays = revenuePeriodDays
        isLoadingActionableInsights = true
        defer { isLoadingActionableInsights = false }

        do {
            let result = try await actor.fetchActionableInsights(periodDays: requestedPeriodDays)
            guard !Task.isCancelled, requestedPeriodDays == revenuePeriodDays else { return }
            revenueDrilldown = result.revenueDrilldown
            serviceProfitability = result.serviceProfitability
        } catch {
            Logger.insights.error("fetchActionableInsights failed: \(error)")
        }
    }

    private func startActionableInsightsRefresh() {
        actionableInsightsTask?.cancel()
        actionableInsightsTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchActionableInsights()
        }
    }
}

private extension Logger {
    static let insights = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "Insights")
}
