//
//  RecentHistoryViewModel.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-09-03.
//

import SwiftUI
import SwiftData

@Observable
@MainActor
final class RecentHistoryViewModel {
    
    // MARK: - State
    var query: String = "" { didSet { scheduleFetch() } }
    var scope: Scope = .all { didSet { scheduleFetch() } }
    
    // MARK: - Published Data
    private(set) var groupedVisits: [Date: [Visit]] = [:]
    private(set) var sortedDays: [Date] = []
    private(set) var summaryVisitCount: Int = 0
    private(set) var summaryRevenueString: String = "$0.00"
    private(set) var isLoading: Bool = false
    var appError: AppError? = nil
    
    // MARK: - Private Properties
    private var dataStore: DataStoreService
    private let eventBus: GlobalEventBus
    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var workSeq: UInt64 = 0
    @ObservationIgnored private let changeLifetime = EventObservationLifetime()
    @ObservationIgnored private let eventLifetime = EventObservationLifetime()
    @ObservationIgnored private var presentationContext: ModelContext?

    init(dataStore: DataStoreService, eventBus: GlobalEventBus = GlobalEventBus()) {
        self.dataStore = dataStore
        self.eventBus = eventBus
        // [weak self] in both observation loops — without it, each for-await
        // captures self strongly, and since neither stream terminates on its
        // own, the VM would never deallocate when the view dismisses.
        let changeStream = dataStore.observeChanges(Visit.self)
        self.changeLifetime.task = Task { [weak self] in
            for await _ in changeStream {
                guard let self else { return }
                self.fetchVisits()
            }
        }
        let stream = eventBus.stream
        self.eventLifetime.task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .checkoutCompleted, .storeCommitted, .refreshRequired, .dataStoreReset:
                    self.fetchVisits()
                default:
                    break
                }
            }
        }
        Task { [weak self] in self?.fetchVisits() }
    }
    
    private func scheduleFetch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300)) // Debounce search
            guard !Task.isCancelled else { return }
            self?.fetchVisits()
        }
    }
    
    func fetchVisits() {
        refreshTask?.cancel()
        self.isLoading = true
        let currentSeq = { workSeq &+= 1; return workSeq }()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        let now = Date()
        let (start, end): (Date?, Date?) = {
            switch scope {
            case .all: return (nil, nil)
            case .today:
                let s = cal.startOfDay(for: now)
                guard let e = cal.date(byAdding: .day, value: 1, to: s) else { return (s, nil) }
                return (s, e)
            case .thisWeek:
                guard let s = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)),
                      let e = cal.date(byAdding: .day, value: 7, to: s) else { return (nil, nil) }
                return (s, e)
            }
        }()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snaps = try await self.fetchCompletedVisitSnapshots(start: start, end: end)
                let result = await Task.detached(priority: .utility) {
                    RecentHistoryComputer.filterAndSummarize(snaps: snaps, query: trimmedQuery)
                }.value

                guard currentSeq == self.workSeq, !Task.isCancelled else { return }
                let filteredModelIDs = snaps
                    .filter { result.filteredIDs.contains($0.id) }
                    .map(\.modelID)
                let reader = ModelContext(self.dataStore.container)
                self.presentationContext = reader
                let filtered = filteredModelIDs.compactMap { reader.model(for: $0) as? Visit }
                let calendar = Calendar.current
                self.summaryVisitCount = filtered.count
                self.summaryRevenueString = result.totalRevenue.moneyString
                self.groupedVisits = Dictionary(grouping: filtered, by: { calendar.startOfDay(for: $0.endedAt ?? $0.startedAt) })
                self.sortedDays = self.groupedVisits.keys.sorted(by: >)
                self.isLoading = false
            } catch {
                guard currentSeq == self.workSeq, !Task.isCancelled else { return }
                self.appError = .database(error.localizedDescription)
                self.groupedVisits = [:]
                self.sortedDays = []
                self.summaryVisitCount = 0
                self.summaryRevenueString = "$0.00"
                self.isLoading = false
            }
        }
    }

    private func fetchCompletedVisitSnapshots(start: Date?, end: Date?) async throws -> [HistoryVisitSnap] {
        let container = dataStore.container

        return try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let sort = [SortDescriptor(\Visit.endedAt, order: .reverse)]
            let visits: [Visit]
            if let start, let end {
                let descriptor = FetchDescriptor<Visit>(
                    predicate: #Predicate<Visit> { visit in
                        if let endedAt = visit.endedAt {
                            endedAt >= start && endedAt < end
                        } else {
                            false
                        }
                    },
                    sortBy: sort
                )
                visits = try context.fetch(descriptor)
            } else {
                let descriptor = FetchDescriptor<Visit>(
                    predicate: #Predicate<Visit> { $0.endedAt != nil },
                    sortBy: sort
                )
                visits = try context.fetch(descriptor)
            }

            return visits.map { v in
                HistoryVisitSnap(
                    modelID: v.persistentModelID,
                    id: v.uuid,
                    startedAt: v.startedAt,
                    endedAt: v.endedAt,
                    petName: v.pet?.name ?? "Unknown",
                    ownerFirst: v.pet?.owner?.firstName ?? "",
                    ownerLast: v.pet?.owner?.lastName ?? "",
                    itemNames: (v.items ?? []).map { $0.name },
                    total: v.total.roundedMoney()
                )
            }
        }.value
    }
    func exportCSV() -> String {
        let allVisits = sortedDays.flatMap { groupedVisits[$0] ?? [] }
        var lines: [String] = []
        lines.append("VisitID,StartedAt,EndedAt,Pet,Owner,Services,Amount,Payment,Reference,Notes")
        
        for v in allVisits {
            let id = v.uuid.uuidString
            let started = Formatters.iso8601.string(from: v.startedAt)
            let ended = v.endedAt.map { Formatters.iso8601.string(from: $0) } ?? ""
            let pet = (v.pet?.name ?? "Unknown").csvEscaped
            let owner = (v.pet?.owner?.fullName ?? "").csvEscaped
            let serviceNames = (v.items ?? []).map { $0.displayName.csvEscaped }
            let services = "\"\(serviceNames.joined(separator: "; "))\""
            let amount = v.total.moneyString
            let payment = (v.payment?.method.displayName ?? "").csvEscaped
            let reference = (v.payment?.externalReference ?? "").csvEscaped
            let notes = (v.note ?? "").replacingOccurrences(of: "\n", with: " ").csvEscaped
            
            let row: [String] = [id, started, ended, pet, owner, services, amount, payment, reference, notes]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

extension RecentHistoryViewModel {
    enum Scope: String, CaseIterable, Identifiable, Hashable {
        case all = "All", today = "Today", thisWeek = "This Week"
        var id: String { rawValue }
    }
}

// MARK: - Background Compute Helpers
fileprivate struct HistoryVisitSnap: Sendable {
    let modelID: PersistentIdentifier
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let petName: String
    let ownerFirst: String
    let ownerLast: String
    let itemNames: [String]
    let total: Decimal
}

fileprivate enum RecentHistoryComputer {
    static func filterAndSummarize(snaps: [HistoryVisitSnap], query: String) -> (filteredIDs: Set<UUID>, totalRevenue: Decimal) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let total = snaps.reduce(Decimal.zero) { ($0 + $1.total).roundedMoney() }
            return (Set(snaps.map { $0.id }), total.roundedMoney())
        }
        
        var ids: Set<UUID> = []
        var total: Decimal = .zero
        for s in snaps {
            let fields: [String] = [s.petName, s.ownerFirst, s.ownerLast] + s.itemNames
            if SearchEngine.matches(trimmed, in: fields) {
                ids.insert(s.id)
                total = (total + s.total).roundedMoney()
            }
        }
        return (ids, total.roundedMoney())
    }
}
