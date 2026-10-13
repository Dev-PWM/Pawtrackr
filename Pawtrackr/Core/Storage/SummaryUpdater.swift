//
//  SummaryUpdater.swift
//  Pawtrackr
//
//  Utilities to maintain DaySummary aggregates.
//

import Foundation
import SwiftData
import OSLog

enum SummaryUpdater {
    struct DayAggregate: Equatable, Sendable {
        let day: Date
        let revenue: Decimal
        let visitCount: Int
    }

    struct ClientInsightAggregate: Equatable, Sendable {
        let clientUUID: UUID
        let clientName: String
        let totalSpent: Decimal
        let visitCount: Int
        let isRecurring: Bool
        let isChurnRisk: Bool
        let lastVisitAt: Date?
        let updatedAt: Date
    }

    static func collapsedDayAggregates(from summaries: [DaySummary]) -> [Date: DayAggregate] {
        summaries.reduce(into: [Date: DayAggregate]()) { result, summary in
            let candidate = DayAggregate(day: summary.day, revenue: summary.revenue, visitCount: summary.visitCount)
            guard let existing = result[summary.day] else {
                result[summary.day] = candidate
                return
            }
            if isPreferred(candidate, over: existing) {
                result[summary.day] = candidate
            }
        }
    }

    static func collapsedServiceCounts(from summaries: [ServiceDaySummary]) -> [String: Int] {
        let perDayAndService = summaries.reduce(into: [SummaryNameKey: Int]()) { result, summary in
            let key = SummaryNameKey(day: summary.day, name: summary.serviceName)
            result[key] = max(result[key] ?? 0, summary.count)
        }
        return perDayAndService.reduce(into: [String: Int]()) { result, entry in
            result[entry.key.name, default: 0] += entry.value
        }
    }

    static func collapsedCategoryCounts(from summaries: [CategoryDaySummary]) -> [String: Int] {
        let perDayAndCategory = summaries.reduce(into: [SummaryNameKey: Int]()) { result, summary in
            let key = SummaryNameKey(day: summary.day, name: summary.categoryRaw)
            result[key] = max(result[key] ?? 0, summary.count)
        }
        return perDayAndCategory.reduce(into: [String: Int]()) { result, entry in
            result[entry.key.name, default: 0] += entry.value
        }
    }

    static func collapsedClientInsightSummaries(from summaries: [ClientInsightSummary]) -> [UUID: ClientInsightAggregate] {
        summaries.reduce(into: [UUID: ClientInsightAggregate]()) { result, summary in
            let candidate = ClientInsightAggregate(
                clientUUID: summary.clientUUID,
                clientName: summary.clientName,
                totalSpent: summary.totalSpent,
                visitCount: summary.visitCount,
                isRecurring: summary.isRecurring,
                isChurnRisk: summary.isChurnRisk,
                lastVisitAt: summary.lastVisitAt,
                updatedAt: summary.updatedAt
            )
            guard let existing = result[summary.clientUUID] else {
                result[summary.clientUUID] = candidate
                return
            }
            if isPreferred(candidate, over: existing) {
                result[summary.clientUUID] = candidate
            }
        }
    }

    /// Recalculate the DaySummary for the calendar day that contains `date`.
    /// Optimized to fetch only the data needed for the specific day.
    static func rebuildDay(for date: Date, in context: ModelContext) {
        do {
            try stageDayRebuild(for: date, in: context)
            if context.hasChanges { try context.save() }
        } catch {
            Logger.summaries.error("Summary rebuild failed: \(String(describing: error))")
        }
    }

    /// Stages day, service, category and client aggregates in the caller's
    /// transaction. Errors propagate so checkout can roll back every model.
    static func stageDayRebuild(for date: Date, in context: ModelContext) throws {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }

        // Fetch only visits that ended on this specific day
        let visits = try fetchVisitsEndedInRange(start: start, end: end, in: context)
        let count = visits.count

        // Primary revenue source: Sum of completed visit totals.
        // Fallback: Sum of payments for the day if no visits are found (e.g. legacy or unlinked payments).
        var revenue = visits.reduce(Decimal.zero) { $0 +~ $1.total }
        if revenue == .zero {
            let payments = try fetchPaymentsInRange(start: start, end: end, in: context)
            revenue = payments.reduce(Decimal.zero) { $0 +~ $1.amount }
        }

        // Upsert DaySummary - fetch only for this day
        let existingSummaries = try fetchDaySummaries(for: start, in: context)
        let existingSummary = canonicalDaySummary(from: existingSummaries, in: context)
        if let s = existingSummary {
            s.revenue = revenue
            s.visitCount = count
        } else {
            context.insert(DaySummary(day: start, revenue: revenue, visitCount: count))
        }

        // Rebuild per-service counts
        var svcCounts: [String: Int] = [:]
        for v in visits {
            for item in v.items ?? [] { svcCounts[item.displayName, default: 0] += 1 }
        }

        let existingSvc = try fetchServiceDaySummaries(for: start, in: context)
        var existingSvcDict = canonicalServiceSummaries(from: existingSvc, in: context)

        for (name, svcCount) in svcCounts {
            if let summary = existingSvcDict[name] {
                summary.count = svcCount
                existingSvcDict.removeValue(forKey: name)
            } else {
                context.insert(ServiceDaySummary(day: start, serviceName: name, count: svcCount))
            }
        }

        for summary in existingSvcDict.values {
            context.delete(summary)
        }

        // Rebuild per-category counts
        var catCounts: [String: Int] = [:]
        for v in visits {
            for item in v.items ?? [] {
                if let raw = item.serviceCategoryRaw ?? item.service?.category?.rawValue {
                    catCounts[raw, default: 0] += 1
                }
            }
        }

        let existingCat = try fetchCategoryDaySummaries(for: start, in: context)
        var existingCatDict = canonicalCategorySummaries(from: existingCat, in: context)

        for (raw, catCount) in catCounts {
            if let summary = existingCatDict[raw] {
                summary.count = catCount
                existingCatDict.removeValue(forKey: raw)
            } else {
                context.insert(CategoryDaySummary(day: start, categoryRaw: raw, count: catCount))
            }
        }

        for summary in existingCatDict.values {
            context.delete(summary)
        }

        var updatedClientUUIDs = Set<UUID>()
        for visit in visits {
            guard let client = visit.pet?.owner, !updatedClientUUIDs.contains(client.uuid) else { continue }
            try upsertClientInsightSummary(for: client, in: context)
            updatedClientUUIDs.insert(client.uuid)
        }
    }

    /// Deletes duplicate cache rows. The summaries are
    /// derived data, so for duplicate keys we keep the highest-count/highest-
    /// revenue row until the next rebuild can recompute from visits.
    static func dedupeSummaryCaches(in context: ModelContext) {
        do {
            let dayRows = try context.fetch(FetchDescriptor<DaySummary>())
            _ = canonicalDaySummaries(from: dayRows, in: context)

            let serviceRows = try context.fetch(FetchDescriptor<ServiceDaySummary>())
            _ = canonicalServiceSummariesByDayAndName(from: serviceRows, in: context)

            let categoryRows = try context.fetch(FetchDescriptor<CategoryDaySummary>())
            _ = canonicalCategorySummariesByDayAndName(from: categoryRows, in: context)

            let clientRows = try context.fetch(FetchDescriptor<ClientInsightSummary>())
            _ = canonicalClientInsightSummaries(from: clientRows, in: context)

            if context.hasChanges {
                try context.save()
            }
        } catch {
            Logger.summaries.error("Summary cache de-dupe failed: \(String(describing: error))")
        }
    }

    // MARK: - Optimized Fetch Helpers

    private static func fetchVisitsEndedInRange(start: Date, end: Date, in context: ModelContext) throws -> [Visit] {
        // SwiftData #Predicate supports date comparisons. Using a precise predicate
        // ensures the database (SQLite) does the heavy lifting, not the main CPU.
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { v in
                if let ended = v.endedAt {
                    return ended >= start && ended < end
                } else {
                    return false
                }
            }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\Visit.items, \Visit.pet]
        return try context.fetch(descriptor)
    }

    private static func fetchPaymentsInRange(start: Date, end: Date, in context: ModelContext) throws -> [Payment] {
        let descriptor = FetchDescriptor<Payment>(
            predicate: #Predicate<Payment> { p in
                p.paidAt >= start && p.paidAt < end
            }
        )
        return try context.fetch(descriptor)
    }

    private static func fetchDaySummaries(for day: Date, in context: ModelContext) throws -> [DaySummary] {
        let descriptor = FetchDescriptor<DaySummary>(
            predicate: #Predicate<DaySummary> { $0.day == day }
        )
        return try context.fetch(descriptor)
    }

    private static func fetchServiceDaySummaries(for day: Date, in context: ModelContext) throws -> [ServiceDaySummary] {
        let descriptor = FetchDescriptor<ServiceDaySummary>(
            predicate: #Predicate<ServiceDaySummary> { $0.day == day }
        )
        return try context.fetch(descriptor)
    }

    private static func fetchCategoryDaySummaries(for day: Date, in context: ModelContext) throws -> [CategoryDaySummary] {
        let descriptor = FetchDescriptor<CategoryDaySummary>(
            predicate: #Predicate<CategoryDaySummary> { $0.day == day }
        )
        return try context.fetch(descriptor)
    }

    /// Rebuild all derived summary rows from canonical Visit data.
    ///
    /// These rows are derived cache data and may be stale or absent after a
    /// local restore. A deterministic rebuild keeps Dashboard/Insights accurate.
    /// A rebuild that finds nothing to change must not save. Returns whether it saved.
    @discardableResult
    static func rebuildAllSummaries(in context: ModelContext) -> Bool {
        let now = Date()
        var saved = false

        do {
            let descriptor = FetchDescriptor<Visit>(
                predicate: #Predicate<Visit> { $0.endedAt != nil },
                sortBy: [SortDescriptor(\.endedAt, order: .forward)]
            )
            let completedVisits = try context.fetch(descriptor)
            let cal = Calendar.current

            var dayStats: [Date: (revenue: Decimal, count: Int)] = [:]
            var serviceStats: [SummaryNameKey: Int] = [:]
            var categoryStats: [SummaryNameKey: Int] = [:]

            for visit in completedVisits {
                guard let endedAt = visit.endedAt else { continue }
                let day = cal.startOfDay(for: endedAt)
                var dayAggregate = dayStats[day] ?? (.zero, 0)
                dayAggregate.revenue += visit.total
                dayAggregate.count += 1
                dayStats[day] = dayAggregate

                for item in visit.items ?? [] {
                    serviceStats[SummaryNameKey(day: day, name: item.displayName), default: 0] += 1
                    if let raw = item.serviceCategoryRaw ?? item.service?.category?.rawValue {
                        categoryStats[SummaryNameKey(day: day, name: raw), default: 0] += 1
                    }
                }
            }

            var clientDesc = FetchDescriptor<Client>()
            clientDesc.relationshipKeyPathsForPrefetching = [\Client.pets]
            let clients = try context.fetch(clientDesc)

            // Cache-warm: pull every Pet with its visits prefetched
            // so the per-client aggregate loop below (which walks each client's
            // pets) doesn't fault relationships one row at a time. Result is
            // intentionally discarded — we just want the relationships warm.
            // Failures are non-critical; the aggregate loop will fault on demand.
            do {
                var petDesc = FetchDescriptor<Pet>()
                petDesc.relationshipKeyPathsForPrefetching = [\.visits]
                _ = try context.fetch(petDesc)
            } catch {
                Logger.dataIntegrity.warning("SummaryUpdater pet prefetch failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }

            let clientStats = clients.reduce(into: [UUID: ClientInsightAggregate]()) { result, client in
                result[client.uuid] = clientInsightAggregate(for: client)
            }

            try replaceDaySummaries(with: dayStats, in: context)
            try replaceServiceSummaries(with: serviceStats, in: context)
            try replaceCategorySummaries(with: categoryStats, in: context)
            try replaceClientInsightSummaries(with: clientStats, in: context)

            if context.hasChanges {
                try context.save()
                saved = true
            }
            UserDefaults.standard.set(now, forKey: "lastSummaryRebuildDate")
            Logger.summaries.info("Full summary rebuild successful: \(completedVisits.count) visits, \(dayStats.count) day rows, saved: \(saved)")
        } catch {
            Logger.summaries.error("Full summary rebuild failed: \(String(describing: error))")
        }
        return saved
    }

    static func upsertClientInsightSummary(for client: Client, in context: ModelContext) throws {
        let aggregate = clientInsightAggregate(for: client)
        let clientUUID = client.uuid
        let descriptor = FetchDescriptor<ClientInsightSummary>(
            predicate: #Predicate<ClientInsightSummary> { $0.clientUUID == clientUUID }
        )
        let existingRows = try context.fetch(descriptor)
        let canonical = canonicalClientInsightSummary(from: existingRows, in: context)

        if let row = canonical {
            apply(aggregate, to: row)
        } else {
            context.insert(ClientInsightSummary(
                clientUUID: aggregate.clientUUID,
                clientName: aggregate.clientName,
                totalSpent: aggregate.totalSpent,
                visitCount: aggregate.visitCount,
                isChurnRisk: aggregate.isChurnRisk,
                lastVisitAt: aggregate.lastVisitAt
            ))
        }
    }

    static func resetSummaryRebuildState() {
        UserDefaults.standard.removeObject(forKey: "lastSummarySyncDate")
        UserDefaults.standard.removeObject(forKey: "lastSummaryRebuildDate")
    }

    // Bring all legacy duplicate cache rows up to date. Readers collapse them
    // by key, and an explicit cache deduplication pass can remove extras.
    private static func replaceDaySummaries(with stats: [Date: (revenue: Decimal, count: Int)], in context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<DaySummary>())
        var seen = Set<Date>()
        for row in rows {
            guard let aggregate = stats[row.day] else {
                context.delete(row)
                continue
            }
            seen.insert(row.day)
            if row.revenue.roundedMoney() != aggregate.revenue.roundedMoney() {
                row.revenue = aggregate.revenue
            }
            assign(aggregate.count, to: \.visitCount, on: row)
        }

        for (day, aggregate) in stats where !seen.contains(day) {
            context.insert(DaySummary(day: day, revenue: aggregate.revenue, visitCount: aggregate.count))
        }
    }

    private static func replaceServiceSummaries(with stats: [SummaryNameKey: Int], in context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<ServiceDaySummary>())
        var seen = Set<SummaryNameKey>()
        for row in rows {
            let key = SummaryNameKey(day: row.day, name: row.serviceName)
            guard let count = stats[key] else {
                context.delete(row)
                continue
            }
            seen.insert(key)
            assign(count, to: \.count, on: row)
        }

        for (key, count) in stats where !seen.contains(key) {
            context.insert(ServiceDaySummary(day: key.day, serviceName: key.name, count: count))
        }
    }

    private static func replaceCategorySummaries(with stats: [SummaryNameKey: Int], in context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<CategoryDaySummary>())
        var seen = Set<SummaryNameKey>()
        for row in rows {
            let key = SummaryNameKey(day: row.day, name: row.categoryRaw)
            guard let count = stats[key] else {
                context.delete(row)
                continue
            }
            seen.insert(key)
            assign(count, to: \.count, on: row)
        }

        for (key, count) in stats where !seen.contains(key) {
            context.insert(CategoryDaySummary(day: key.day, categoryRaw: key.name, count: count))
        }
    }

    private static func replaceClientInsightSummaries(
        with stats: [UUID: ClientInsightAggregate],
        in context: ModelContext
    ) throws {
        let rows = try context.fetch(FetchDescriptor<ClientInsightSummary>())
        var seen = Set<UUID>()
        for row in rows {
            guard let aggregate = stats[row.clientUUID] else {
                context.delete(row)
                continue
            }
            seen.insert(row.clientUUID)
            apply(aggregate, to: row)
        }

        for aggregate in stats.values where !seen.contains(aggregate.clientUUID) {
            context.insert(ClientInsightSummary(
                clientUUID: aggregate.clientUUID,
                clientName: aggregate.clientName,
                totalSpent: aggregate.totalSpent,
                visitCount: aggregate.visitCount,
                isChurnRisk: aggregate.isChurnRisk,
                lastVisitAt: aggregate.lastVisitAt
            ))
        }
    }

    /// SwiftData marks a row changed on any assignment, even of the value it
    /// already holds, and a changed mirrored row is uploaded. So summary
    /// writers compare first.
    private static func assign<Row: AnyObject, Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<Row, Value>,
        on row: Row
    ) {
        if row[keyPath: keyPath] != value {
            row[keyPath: keyPath] = value
        }
    }

    /// `update` also stamps `updatedAt`, so it only runs when a field differs.
    private static func apply(_ aggregate: ClientInsightAggregate, to row: ClientInsightSummary) {
        let unchanged = row.clientName == aggregate.clientName
            && row.totalSpent.roundedMoney() == aggregate.totalSpent.roundedMoney()
            && row.visitCount == aggregate.visitCount
            && row.isRecurring == (aggregate.visitCount > 1)
            && row.isChurnRisk == aggregate.isChurnRisk
            && row.lastVisitAt == aggregate.lastVisitAt
        guard !unchanged else { return }
        row.update(
            clientName: aggregate.clientName,
            totalSpent: aggregate.totalSpent,
            visitCount: aggregate.visitCount,
            isChurnRisk: aggregate.isChurnRisk,
            lastVisitAt: aggregate.lastVisitAt
        )
    }

    private static func clientInsightAggregate(for client: Client) -> ClientInsightAggregate {
        let pets = client.pets ?? []
        let visits = pets.flatMap { $0.visits ?? [] }.filter { $0.isCompleted }
        let spent = visits.reduce(Decimal.zero) { $0 +~ $1.total }
        let lastVisitAt = visits.compactMap(\.endedAt).max()

        return ClientInsightAggregate(
            clientUUID: client.uuid,
            clientName: client.fullName,
            totalSpent: spent.roundedMoney(),
            visitCount: visits.count,
            isRecurring: visits.count > 1,
            isChurnRisk: pets.contains { $0.isOverdue },
            lastVisitAt: lastVisitAt,
            updatedAt: .now
        )
    }

    /// Synchronous version that reuses already-fetched visits for efficiency
    private static func rebuildDaySync(
        for date: Date,
        allVisits: [Visit],
        existingSummary: DaySummary?,
        existingServiceSummaries: [ServiceDaySummary],
        in context: ModelContext
    ) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }

        // Filter visits for this day
        let visits = allVisits.filter { visit in
            guard let endedAt = visit.endedAt else { return false }
            return endedAt >= start && endedAt < end
        }
        let count = visits.count
        let revenue = visits.reduce(Decimal.zero) { $0 +~ $1.total }

        // Upsert DaySummary
        if let s = existingSummary {
            s.revenue = revenue
            s.visitCount = count
        } else {
            context.insert(DaySummary(day: start, revenue: revenue, visitCount: count))
        }

        // Rebuild per-service counts
        var svcCounts: [String: Int] = [:]
        for v in visits {
            for item in v.items ?? [] { svcCounts[item.displayName, default: 0] += 1 }
        }

        var existingSvcDict = existingServiceSummaries.reduce(into: [String: ServiceDaySummary]()) { $0[$1.serviceName] = $1 }

        for (name, svcCount) in svcCounts {
            if let summary = existingSvcDict[name] {
                summary.count = svcCount
                existingSvcDict.removeValue(forKey: name)
            } else {
                context.insert(ServiceDaySummary(day: start, serviceName: name, count: svcCount))
            }
        }

        for summary in existingSvcDict.values {
            context.delete(summary)
        }
    }

    private struct SummaryNameKey: Hashable {
        let day: Date
        let name: String
    }

    private static func isPreferred(_ candidate: DayAggregate, over existing: DayAggregate) -> Bool {
        if candidate.visitCount != existing.visitCount {
            return candidate.visitCount > existing.visitCount
        }
        return candidate.revenue > existing.revenue
    }

    private static func isPreferred(_ candidate: DaySummary, over existing: DaySummary) -> Bool {
        if candidate.visitCount != existing.visitCount {
            return candidate.visitCount > existing.visitCount
        }
        return candidate.revenue > existing.revenue
    }

    private static func isPreferred(_ candidate: ClientInsightAggregate, over existing: ClientInsightAggregate) -> Bool {
        if candidate.visitCount != existing.visitCount {
            return candidate.visitCount > existing.visitCount
        }
        if candidate.totalSpent != existing.totalSpent {
            return candidate.totalSpent > existing.totalSpent
        }
        return candidate.updatedAt > existing.updatedAt
    }

    private static func isPreferred(_ candidate: ClientInsightSummary, over existing: ClientInsightSummary) -> Bool {
        if candidate.visitCount != existing.visitCount {
            return candidate.visitCount > existing.visitCount
        }
        if candidate.totalSpent != existing.totalSpent {
            return candidate.totalSpent > existing.totalSpent
        }
        return candidate.updatedAt > existing.updatedAt
    }

    private static func canonicalDaySummary(from summaries: [DaySummary], in context: ModelContext) -> DaySummary? {
        canonicalDaySummaries(from: summaries, in: context).values.first
    }

    private static func canonicalDaySummaries(from summaries: [DaySummary], in context: ModelContext) -> [Date: DaySummary] {
        var result: [Date: DaySummary] = [:]
        for summary in summaries {
            if let existing = result[summary.day] {
                if isPreferred(summary, over: existing) {
                    context.delete(existing)
                    result[summary.day] = summary
                } else {
                    context.delete(summary)
                }
            } else {
                result[summary.day] = summary
            }
        }
        return result
    }

    private static func canonicalServiceSummaries(from summaries: [ServiceDaySummary], in context: ModelContext) -> [String: ServiceDaySummary] {
        var result: [String: ServiceDaySummary] = [:]
        for summary in summaries {
            if let existing = result[summary.serviceName] {
                if summary.count > existing.count {
                    context.delete(existing)
                    result[summary.serviceName] = summary
                } else {
                    context.delete(summary)
                }
            } else {
                result[summary.serviceName] = summary
            }
        }
        return result
    }

    private static func canonicalCategorySummaries(from summaries: [CategoryDaySummary], in context: ModelContext) -> [String: CategoryDaySummary] {
        var result: [String: CategoryDaySummary] = [:]
        for summary in summaries {
            if let existing = result[summary.categoryRaw] {
                if summary.count > existing.count {
                    context.delete(existing)
                    result[summary.categoryRaw] = summary
                } else {
                    context.delete(summary)
                }
            } else {
                result[summary.categoryRaw] = summary
            }
        }
        return result
    }

    private static func canonicalServiceSummariesByDayAndName(from summaries: [ServiceDaySummary], in context: ModelContext) -> [SummaryNameKey: ServiceDaySummary] {
        var result: [SummaryNameKey: ServiceDaySummary] = [:]
        for summary in summaries {
            let key = SummaryNameKey(day: summary.day, name: summary.serviceName)
            if let existing = result[key] {
                if summary.count > existing.count {
                    context.delete(existing)
                    result[key] = summary
                } else {
                    context.delete(summary)
                }
            } else {
                result[key] = summary
            }
        }
        return result
    }

    private static func canonicalCategorySummariesByDayAndName(from summaries: [CategoryDaySummary], in context: ModelContext) -> [SummaryNameKey: CategoryDaySummary] {
        var result: [SummaryNameKey: CategoryDaySummary] = [:]
        for summary in summaries {
            let key = SummaryNameKey(day: summary.day, name: summary.categoryRaw)
            if let existing = result[key] {
                if summary.count > existing.count {
                    context.delete(existing)
                    result[key] = summary
                } else {
                    context.delete(summary)
                }
            } else {
                result[key] = summary
            }
        }
        return result
    }

    private static func canonicalClientInsightSummary(from summaries: [ClientInsightSummary], in context: ModelContext) -> ClientInsightSummary? {
        canonicalClientInsightSummaries(from: summaries, in: context).values.first
    }

    private static func canonicalClientInsightSummaries(from summaries: [ClientInsightSummary], in context: ModelContext) -> [UUID: ClientInsightSummary] {
        var result: [UUID: ClientInsightSummary] = [:]
        for summary in summaries {
            if let existing = result[summary.clientUUID] {
                if isPreferred(summary, over: existing) {
                    context.delete(existing)
                    result[summary.clientUUID] = summary
                } else {
                    context.delete(summary)
                }
            } else {
                result[summary.clientUUID] = summary
            }
        }
        return result
    }
}

private extension Logger {
    static let summaries = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "summaries")
}
