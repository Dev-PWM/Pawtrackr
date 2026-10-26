//
//  InsightsActor.swift
//  Pawtrackr
//
//  Dedicated background actor for heavy analytics, aggregation, and pre-fetching.
//  Ensures Insights logic never blocks the MainActor and enables anticipatory loading.
//

import Foundation
import SwiftData
import OSLog

@ModelActor
public final actor InsightsActor {
    
    struct RevenueResult: Sendable {
        let series: [InsightsViewModel.RevenueData]
        let totalRevenue: Decimal
        let totalVisits: Int
        let averageVisitValue: Decimal
        /// The first day of the period through the start of the day after today,
        /// so the chart spans every day of the period, empty days included.
        let window: ClosedRange<Date>
    }
    
    struct DistributionResult: Sendable {
        let services: [InsightsViewModel.DistributionData]
        let categories: [InsightsViewModel.DistributionData]
        let payments: [InsightsViewModel.PaymentMethodData]
    }
    
    struct ClientInsightsResult: Sendable {
        let retentionRate: Double
        let churnRiskCount: Int
        let retentionSeries: [InsightsViewModel.RetentionData]
    }

    struct ActionableInsightsResult: Sendable {
        let revenueDrilldown: [InsightsViewModel.RevenueVisitData]
        let serviceProfitability: [InsightsViewModel.ServiceProfitabilityData]
    }
    
    // MARK: - Core Analytics
    
    func fetchRevenue(periodDays: Int) async throws -> RevenueResult {
        let period = try Self.periodWindow(days: periodDays)
        let start = period.start
        let end = period.today
        
        var descriptor = FetchDescriptor<DaySummary>(
            predicate: #Predicate<DaySummary> { summary in
                summary.day >= start && summary.day <= end
            }
        )
        descriptor.fetchLimit = 500
        
        let summaries = try modelContext.fetch(descriptor)
        let aggregates = SummaryUpdater.collapsedDayAggregates(from: summaries).values.sorted { $0.day < $1.day }
        
        let totalVisits = aggregates.reduce(0) { $0 + $1.visitCount }
        let totalRevenue = aggregates.reduce(Decimal.zero) { $0 + $1.revenue }
        
        return RevenueResult(
            series: aggregates.map { InsightsViewModel.RevenueData(date: $0.day, amount: $0.revenue) },
            totalRevenue: totalRevenue,
            totalVisits: totalVisits,
            averageVisitValue: totalVisits > 0 ? totalRevenue / Decimal(totalVisits) : .zero,
            window: period.start...period.end
        )
    }

    /// Services, categories and payment methods for the same days as the
    /// revenue card, so the cards and the exported report agree.
    func fetchDistributions(periodDays: Int) async throws -> DistributionResult {
        let period = try Self.periodWindow(days: periodDays)
        let start = period.start
        let end = period.end
        
        // 1. Fetch Visits with pre-fetching
        var visitsDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { visit in
                if let endedAt = visit.endedAt {
                    endedAt >= start && endedAt < end
                } else {
                    false
                }
            }
        )
        visitsDescriptor.fetchLimit = 1_000
        visitsDescriptor.relationshipKeyPathsForPrefetching = [\.items]
        let visits = try modelContext.fetch(visitsDescriptor)
        
        // 2. Fetch Category Summaries
        let categoryDescriptor = FetchDescriptor<CategoryDaySummary>(
            predicate: #Predicate<CategoryDaySummary> { $0.day >= start && $0.day < end }
        )
        let categories = try modelContext.fetch(categoryDescriptor)
        
        // 3. Fetch Payments
        let paymentDescriptor = FetchDescriptor<Payment>(
            predicate: #Predicate<Payment> { $0.paidAt >= start && $0.paidAt < end }
        )
        let payments = try modelContext.fetch(paymentDescriptor)
        
        // Aggregate Services
        var serviceStats: [String: (count: Int, revenue: Decimal)] = [:]
        for visit in visits {
            for item in visit.items ?? [] {
                serviceStats[item.name, default: (0, .zero)].count   += 1
                serviceStats[item.name, default: (0, .zero)].revenue += item.lineTotal
            }
        }
        
        let services = serviceStats
            .map { InsightsViewModel.DistributionData(name: $0.key, count: $0.value.count, revenue: $0.value.revenue) }
            .sorted {
                if $0.revenue != $1.revenue { return $0.revenue > $1.revenue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        
        let categoryDist = SummaryUpdater.collapsedCategoryCounts(from: categories)
            .map { InsightsViewModel.DistributionData(name: $0.key, count: $0.value) }
            .sorted(by: Self.sortCategoryDistribution)
        
        let paymentDist = Dictionary(grouping: payments, by: \.method)
            .map { method, rows in
                InsightsViewModel.PaymentMethodData(
                    method: method,
                    count: rows.count,
                    amount: rows.reduce(.zero) { $0 + $1.amount }
                )
            }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.method.displayName.localizedStandardCompare($1.method.displayName) == .orderedAscending
            }
            
        return DistributionResult(services: services, categories: categoryDist, payments: paymentDist)
    }

    private static func sortCategoryDistribution(
        _ lhs: InsightsViewModel.DistributionData,
        _ rhs: InsightsViewModel.DistributionData
    ) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        let lhsRank = categoryRank(lhs.name)
        let rhsRank = categoryRank(rhs.name)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func categoryRank(_ name: String) -> Int {
        switch name {
        case Service.Category.package.rawValue: return 0
        case Service.Category.groom.rawValue: return 1
        case Service.Category.addOn.rawValue: return 2
        case Service.Category.care.rawValue: return 3
        default: return 10
        }
    }
    
    func fetchClientInsights() async throws -> ClientInsightsResult {
        var summaryDesc = FetchDescriptor<ClientInsightSummary>(
            sortBy: [SortDescriptor(\.totalSpent, order: .reverse)]
        )
        summaryDesc.fetchLimit = 5000
        let summaries = try modelContext.fetch(summaryDesc)
        
        if !summaries.isEmpty {
            let collapsed = Array(SummaryUpdater.collapsedClientInsightSummaries(from: summaries).values)
            let recurring = collapsed.filter(\.isRecurring).count
            let churn = collapsed.filter(\.isChurnRisk).count
            let oneTime = max(0, collapsed.count - recurring)

            let series = [
                InsightsViewModel.RetentionData(
                    label: NSLocalizedString("insights.retention.recurring", value: "Recurring", comment: ""),
                    value: Double(recurring)
                ),
                InsightsViewModel.RetentionData(
                    label: NSLocalizedString("insights.retention.one_time", value: "One-time", comment: ""),
                    value: Double(oneTime)
                )
            ]

            return ClientInsightsResult(
                retentionRate: collapsed.isEmpty ? 0 : Double(recurring) / Double(collapsed.count),
                churnRiskCount: churn,
                retentionSeries: series
            )
        }
        
        // Fallback to legacy calculation if no summaries
        return try await calculateLegacyClientInsights()
    }
    
    func fetchMonthlyGrowth() async throws -> [InsightsViewModel.MonthlyGrowthData] {
        let cal = Calendar.current
        let now = Date()
        let monthFormatter = DateFormatter()
        // The app's language setting, not the device's, like the rest of Insights.
        monthFormatter.locale = AppLocalization.currentLocale
        monthFormatter.setLocalizedDateFormatFromTemplate("MMM")

        guard let earliestMonthDate = cal.date(byAdding: .month, value: -5, to: now),
              let rangeStart = cal.date(from: cal.dateComponents([.year, .month], from: earliestMonthDate)),
              let rangeEnd   = cal.date(byAdding: .month, value: 1, to: cal.startOfDay(for: now))
        else { return [] }

        let descriptor = FetchDescriptor<DaySummary>(
            predicate: #Predicate<DaySummary> { $0.day >= rangeStart && $0.day < rangeEnd }
        )
        let summaries = try modelContext.fetch(descriptor)
        let collapsed = SummaryUpdater.collapsedDayAggregates(from: summaries)

        var buckets: [(start: Date, label: String, revenue: Decimal, count: Int)] = []
        for i in (0..<6).reversed() {
            guard let monthDate  = cal.date(byAdding: .month, value: -i, to: now),
                  let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: monthDate))
            else { continue }
            buckets.append((start: monthStart, label: monthFormatter.string(from: monthStart), revenue: .zero, count: 0))
        }

        for summary in collapsed.values {
            let ms = cal.date(from: cal.dateComponents([.year, .month], from: summary.day))
            guard let ms, let idx = buckets.firstIndex(where: { $0.start == ms }) else { continue }
            buckets[idx].revenue += summary.revenue
            buckets[idx].count   += summary.visitCount
        }

        return buckets.map {
            InsightsViewModel.MonthlyGrowthData(month: $0.label, revenue: $0.revenue, visitCount: $0.count)
        }
    }

    func fetchActionableInsights(periodDays: Int) async throws -> ActionableInsightsResult {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let normalizedPeriod = max(1, min(periodDays, 365))
        let currentStart = cal.date(byAdding: .day, value: -(normalizedPeriod - 1), to: today) ?? today
        let priorStart = cal.date(byAdding: .day, value: -normalizedPeriod, to: currentStart) ?? currentStart

        var visitDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { visit in
                if let endedAt = visit.endedAt {
                    endedAt >= priorStart && endedAt < tomorrow
                } else {
                    false
                }
            }
        )
        visitDescriptor.fetchLimit = 3_000
        visitDescriptor.relationshipKeyPathsForPrefetching = [\.items]
        let visits = try modelContext.fetch(visitDescriptor)

        let currentVisits = visits
            .filter { ($0.endedAt ?? $0.startedAt) >= currentStart && ($0.endedAt ?? $0.startedAt) < tomorrow }
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }

        let priorVisits = visits
            .filter { ($0.endedAt ?? $0.startedAt) >= priorStart && ($0.endedAt ?? $0.startedAt) < currentStart }

        let revenueRows = currentVisits.prefix(50).map { visit in
            InsightsViewModel.RevenueVisitData(
                date: visit.endedAt ?? visit.startedAt,
                petName: visit.pet?.name ?? "Unknown pet",
                clientName: visit.pet?.owner?.fullName ?? "Unknown client",
                serviceSummary: Self.serviceSummary(for: visit),
                total: visit.total,
                paymentMethod: visit.payment?.method.displayName ?? "Unpaid"
            )
        }

        let serviceProfitability = Self.serviceProfitability(currentVisits: currentVisits, priorVisits: priorVisits)

        return ActionableInsightsResult(
            revenueDrilldown: revenueRows,
            serviceProfitability: serviceProfitability
        )
    }
    
    // MARK: - Private Helpers

    /// `days` calendar days ending with today: `start` is the first day,
    /// `today` the last, and `end` the start of tomorrow. Day arithmetic
    /// keeps the bounds on midnight across daylight-saving changes.
    private static func periodWindow(days: Int, now: Date = .now) throws -> (start: Date, today: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: today),
              let end = cal.date(byAdding: .day, value: 1, to: today)
        else {
            throw AppError.validation(.custom(message: AppLocalization.localized("validation.invalid_date_range", value: "The selected date range is invalid.")))
        }
        return (start, today, end)
    }
    
    private func calculateLegacyClientInsights() async throws -> ClientInsightsResult {
        var clientDesc = FetchDescriptor<Client>()
        clientDesc.relationshipKeyPathsForPrefetching = [\.pets]
        clientDesc.fetchLimit = 5000
        let clients = try modelContext.fetch(clientDesc)

        var recurring = 0
        var churn = 0

        for client in clients {
            let visits = (client.pets ?? []).flatMap { $0.visits ?? [] }.filter { $0.isCompleted }

            if visits.count > 1 { recurring += 1 }
            if (client.pets ?? []).contains(where: { $0.archivedAt == nil && $0.isOverdue }) { churn += 1 }
        }

        let oneTime = clients.count - recurring
        let series = [
            InsightsViewModel.RetentionData(
                label: NSLocalizedString("insights.retention.recurring", value: "Recurring", comment: ""),
                value: Double(recurring)
            ),
            InsightsViewModel.RetentionData(
                label: NSLocalizedString("insights.retention.one_time", value: "One-time", comment: ""),
                value: Double(oneTime)
            )
        ]

        return ClientInsightsResult(
            retentionRate: clients.isEmpty ? 0 : Double(recurring) / Double(clients.count),
            churnRiskCount: churn,
            retentionSeries: series
        )
    }

    private static func serviceSummary(for visit: Visit) -> String {
        let names = (visit.items ?? []).map(\.displayName).filter { !$0.isEmpty }
        if names.isEmpty { return "No services listed" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    private static func serviceProfitability(currentVisits: [Visit], priorVisits: [Visit]) -> [InsightsViewModel.ServiceProfitabilityData] {
        typealias ServiceStats = (category: String, count: Int, revenue: Decimal)
        var current: [String: ServiceStats] = [:]
        var prior: [String: ServiceStats] = [:]

        func add(_ item: VisitItem, to stats: inout [String: ServiceStats]) {
            let category = item.serviceCategoryRaw.flatMap(Service.Category.init(rawValue:))?.rawValue ?? "Uncategorized"
            let existing = stats[item.name] ?? (category, 0, .zero)
            stats[item.name] = (existing.category, existing.count + item.quantity, existing.revenue + item.lineTotal)
        }

        for visit in currentVisits {
            for item in visit.items ?? [] {
                add(item, to: &current)
            }
        }

        for visit in priorVisits {
            for item in visit.items ?? [] {
                add(item, to: &prior)
            }
        }

        let currentProfitability = current.map { name, stats -> InsightsViewModel.ServiceProfitabilityData in
            let priorRevenue = prior[name]?.revenue ?? .zero
            let trend: Double
            if priorRevenue > .zero {
                let delta = stats.revenue - priorRevenue
                let trendValue = (delta / priorRevenue) as NSDecimalNumber
                trend = trendValue.doubleValue.isFinite ? trendValue.doubleValue : (delta > 0 ? 1.0 : -1.0)
            } else {
                trend = stats.revenue > .zero ? 1.0 : 0.0
            }

            return InsightsViewModel.ServiceProfitabilityData(
                name: name,
                category: stats.category,
                count: stats.count,
                revenue: stats.revenue,
                averageTicket: stats.count > 0 ? (stats.revenue / Decimal(stats.count)).roundedMoney() : .zero,
                trendPercent: trend
            )
        }
        
        return currentProfitability
            .sorted { $0.revenue > $1.revenue }
            .prefix(10)
            .map { $0 }
    }

}
