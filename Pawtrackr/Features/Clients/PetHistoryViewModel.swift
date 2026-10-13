//
//  PetHistoryViewModel.swift
//  Pawtrackr
//

import Foundation
import SwiftUI
import SwiftData

private final class NotificationObserverToken {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@Observable
@MainActor
final class PetHistoryViewModel {
    // MARK: - Types
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        var id: String { rawValue }

        /// Localized label shown in the Picker. The `rawValue` strings are
        /// kept stable so existing call sites (e.g. analytics, persistence)
        /// don't break, but UI now goes through this accessor.
        var displayName: String {
            switch self {
            case .all:       return NSLocalizedString("pet_history.scope.all",        value: "All",        comment: "")
            case .today:     return NSLocalizedString("pet_history.scope.today",      value: "Today",      comment: "")
            case .thisWeek:  return NSLocalizedString("pet_history.scope.this_week",  value: "This Week",  comment: "")
            case .thisMonth: return NSLocalizedString("pet_history.scope.this_month", value: "This Month", comment: "")
            }
        }
    }

    // MARK: - Inputs / Environment
    private let modelContext: ModelContext
    @ObservationIgnored private var presentationContext: ModelContext?
    var pet: Pet

    // MARK: - Filtering
    var scope: Scope = .thisMonth {
        didSet {
            currentLimit = pageSize
            scheduleRefresh()
        }
    }
    var searchText: String = "" { didSet { applyFiltersAndKPIs() } }

    // MARK: - Output
    private(set) var visits: [Visit] = []
    private(set) var filtered: [Visit] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = false
    var appError: AppError? = nil

    // MARK: - KPIs
    private(set) var totalVisits: Int = 0
    private(set) var totalSpent: Decimal = .zero
    private(set) var averageDuration: TimeInterval = 0

    var totalSpentString: String { totalSpent.moneyString }
    var averageDurationString: String {
        Formatters.durationString(from: Date(), to: Date().addingTimeInterval(averageDuration))
    }

    private let pageSize = 100
    private var currentLimit = 100
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var snapshots: [PetHistoryVisitSnapshot] = []
    private var filteredSnapshots: [PetHistoryVisitSnapshot] = []
    private var visitCompleteObserver: NotificationObserverToken?
    @ObservationIgnored private let observationLifetime = EventObservationLifetime()

    // MARK: - Init
    init(pet: Pet, modelContext: ModelContext, eventBus: GlobalEventBus = GlobalEventBus()) {
        self.pet = pet
        self.modelContext = modelContext
        let petID = pet.persistentModelID
        let token = NotificationCenter.default.addObserver(
            forName: .visitDidComplete, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let completedPetID = notification.petID, completedPetID != petID { return }
            Task { [weak self] in
                await self?.refresh()
            }
        }
        visitCompleteObserver = NotificationObserverToken(token)
        let stream = eventBus.stream
        observationLifetime.task = Task { [weak self] in
            for await event in stream {
                switch event {
                case .storeCommitted, .refreshRequired:
                    await self?.refresh()
                default:
                    break
                }
            }
        }
    }

    // MARK: - Public
    func refresh() async {
        let generation = nextRefreshGeneration()
        isLoading = true
        appError = nil

        do {
            let fetched = try await fetchVisitSnapshots()
            guard generation == refreshGeneration else { return }
            snapshots = fetched.rows
            canLoadMore = fetched.hasMore
            let reader = ModelContext(modelContext.container)
            presentationContext = reader
            visits = snapshots.compactMap { reader.model(for: $0.modelID) as? Visit }
            applyFiltersAndKPIs()
        } catch {
            guard generation == refreshGeneration else { return }
            snapshots = []
            filteredSnapshots = []
            visits = []
            filtered = []
            canLoadMore = false
            appError = .database(error.localizedDescription)
            computeKPIs()
        }

        isLoading = false
    }

    func loadMore() {
        guard canLoadMore, !isLoading else { return }
        currentLimit += pageSize
        scheduleRefresh()
    }

    func exportCSV() -> Data {
        let header = ["Date", "Services", "Duration", "Amount"]
        let rows: [[String]] = filteredSnapshots.map { visit in
            let date = visit.startedAt.formatted(date: .abbreviated, time: .omitted)
            let services = visit.itemNames.joined(separator: ", ")
            let duration = Formatters.durationString(from: visit.startedAt, to: visit.endedAt)
            let amount = NSDecimalNumber(decimal: visit.total.roundedMoney()).stringValue
            return [date, services, duration, amount]
        }
        let lines = ([header] + rows).map { $0.map { $0.csvEscaped }.joined(separator: ",") }.joined(separator: "\n")
        return Data(lines.utf8)
    }

    func exportPlainText() -> String {
        var out = ""
        for visit in filteredSnapshots {
            let date = visit.startedAt.formatted(date: .abbreviated, time: .shortened)
            let duration = Formatters.durationString(from: visit.startedAt, to: visit.endedAt)
            let amount = visit.total.moneyString
            let services = visit.itemNames.joined(separator: ", ")
            out += "\n• \(date) — \(services) — \(duration) — \(amount)"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private
    private func nextRefreshGeneration() -> UInt64 {
        refreshGeneration &+= 1
        return refreshGeneration
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func fetchVisitSnapshots() async throws -> (rows: [PetHistoryVisitSnapshot], hasMore: Bool) {
        let (start, end) = dateBounds(for: scope)
        let petUUID = pet.uuid
        let container = modelContext.container
        let fetchLimit = currentLimit + 1

        return try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let predicate: Predicate<Visit>
            switch (start, end) {
            case let (s?, e?):
                predicate = #Predicate<Visit> { visit in
                    if let endedAt = visit.endedAt {
                        endedAt >= s && endedAt < e && visit.pet?.uuid == petUUID
                    } else {
                        false
                    }
                }
            case let (s?, nil):
                predicate = #Predicate<Visit> { visit in
                    if let endedAt = visit.endedAt {
                        endedAt >= s && visit.pet?.uuid == petUUID
                    } else {
                        false
                    }
                }
            case let (nil, e?):
                predicate = #Predicate<Visit> { visit in
                    if let endedAt = visit.endedAt {
                        endedAt < e && visit.pet?.uuid == petUUID
                    } else {
                        false
                    }
                }
            case (nil, nil):
                predicate = #Predicate<Visit> { visit in
                    visit.endedAt != nil && visit.pet?.uuid == petUUID
                }
            }

            var descriptor = FetchDescriptor<Visit>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
            )
            descriptor.fetchLimit = fetchLimit
            descriptor.relationshipKeyPathsForPrefetching = [\Visit.items, \Visit.payment]

            let fetched = try context.fetch(descriptor).filter { $0.payment != nil }
            let rows = fetched.map { visit in
                PetHistoryVisitSnapshot(
                    modelID: visit.persistentModelID,
                    startedAt: visit.startedAt,
                    endedAt: visit.endedAt ?? visit.startedAt,
                    itemNames: (visit.items ?? []).map(\.name),
                    note: visit.note,
                    externalReference: visit.payment?.externalReference,
                    total: visit.total
                )
            }
            return (Array(rows.prefix(fetchLimit - 1)), fetched.count >= fetchLimit)
        }.value
    }

    private func applyFiltersAndKPIs() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            filteredSnapshots = snapshots
            filtered = visits
        } else {
            filteredSnapshots = snapshots.filter { $0.matches(query: q) }
            let filteredIDs = Set(filteredSnapshots.map(\.modelID))
            filtered = visits.filter { filteredIDs.contains($0.persistentModelID) }
        }
        computeKPIs()
    }

    private func computeKPIs() {
        totalVisits = filteredSnapshots.count
        totalSpent = filteredSnapshots.reduce(.zero) { $0 + $1.total }
        let totalDur = filteredSnapshots.reduce(0) { $0 + $1.duration }
        averageDuration = totalVisits > 0 ? totalDur / Double(max(1, totalVisits)) : 0
    }

    private func dateBounds(for scope: Scope) -> (Date?, Date?) {
        let cal = Calendar.current
        let now = Date()
        switch scope {
        case .all:
            return (nil, nil)
        case .today:
            let start = cal.startOfDay(for: now)
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return (start, nil) }
            return (start, end)
        case .thisWeek:
            guard let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)),
                  let end = cal.date(byAdding: .day, value: 7, to: start) else {
                return (nil, nil)
            }
            return (start, end)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            guard let start = cal.date(from: comps),
                  let end = cal.date(byAdding: .month, value: 1, to: start) else {
                return (nil, nil)
            }
            return (start, end)
        }
    }
}

private struct PetHistoryVisitSnapshot: Sendable {
    let modelID: PersistentIdentifier
    let startedAt: Date
    let endedAt: Date
    let itemNames: [String]
    let note: String?
    let externalReference: String?
    let total: Decimal

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    func matches(query: String) -> Bool {
        let fields = itemNames + [note, externalReference].compactMap { $0 }
        return SearchEngine.matches(query, in: fields)
    }
}

// MARK: - Shareable docs (optional Transferables)
struct PetHistoryCSV: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { $0.data }
    }
    let data: Data
}

struct PetHistoryText: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { Data($0.text.utf8) }
    }
    let text: String
}
