//
//  ClientsViewModel.swift
//  Pawtrackr
//


import SwiftUI
import SwiftData
import Combine
import OSLog

/// Cancels the stream subscription when the list model releases its owner.
/// Task handles are Sendable; this cleanup needs no hop back to MainActor.
private final class ClientListEventTaskOwner {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}

@Observable
@MainActor
final class ClientsViewModel {
    enum Filter: String, CaseIterable, Sendable {
        case all = "All"
        case active = "Active"
        case overdue = "Overdue"
        case missingInfo = "Missing Info"

        var displayName: String {
            switch self {
            case .all:
                return NSLocalizedString("clients.filter.all", value: "All", comment: "")
            case .active:
                return NSLocalizedString("clients.filter.active", value: "Active", comment: "")
            case .overdue:
                return NSLocalizedString("clients.filter.overdue", value: "Needs Attention", comment: "")
            case .missingInfo:
                return NSLocalizedString("clients.filter.missing_info", value: "Missing Info", comment: "")
            }
        }
    }

    enum SortOption: String, CaseIterable, Sendable {
        case lastName = "Last Name"
        case firstName = "First Name"
        case petName = "Pet's Name"
        case lastVisit = "Last Visit"
        case newest = "Newest"

        var displayName: String {
            switch self {
            case .lastName:
                return NSLocalizedString("clients.sort.last_name", value: "Last Name", comment: "")
            case .firstName:
                return NSLocalizedString("clients.sort.first_name", value: "First Name", comment: "")
            case .petName:
                return NSLocalizedString("clients.sort.pet_name", value: "Pet's Name", comment: "")
            case .lastVisit:
                return NSLocalizedString("clients.sort.last_visit", value: "Last Visit", comment: "")
            case .newest:
                return NSLocalizedString("clients.sort.newest", value: "Newest", comment: "")
            }
        }
    }

    // MARK: - Published Properties
    var inProgressClients: [Client] = []
    var otherClients: [Client] = []
    var needsAttentionClients: [Client] = []
    
    var searchText = "" {
        didSet { scheduleFetch() }
    }
    
    var selectedFilter: Filter = .all {
        didSet { fetchClients() }
    }

    var sortOption: SortOption = .lastName {
        didSet {
            fetchClients()
        }
    }

    var inProgressCount: Int { inProgressClients.count }
    var canLoadMore: Bool = false
    var isLoadingMore: Bool = false
    var appError: AppError? = nil
    
    // MARK: - Private Properties
    private let modelContext: ModelContext
    private let repository: ClientRepositoryProtocol
    private let eventBus: GlobalEventBus?
    private var searchTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil
    private var loadMoreTask: Task<Void, Never>? = nil
    private var deleteTask: Task<Void, Never>? = nil
    @ObservationIgnored private let eventTaskOwner = ClientListEventTaskOwner()
    private var cancellables: Set<AnyCancellable> = []
    private var pageSize: Int = 100
    private var fetchOffset: Int = 0
    /// Clients the list loads per query. Filters and sorts run over this whole
    /// set in memory, so it is not a page size (see `fetchClients`).
    static let clientListFetchLimit = 1000

    // MARK: - Lifecycle
    init(modelContext: ModelContext, eventBus: GlobalEventBus? = nil, repository: ClientRepositoryProtocol? = nil) {
        self.modelContext = modelContext
        self.repository = repository ?? ClientRepository(modelContainer: modelContext.container)
        self.eventBus = eventBus
        fetchClients() // Initial fetch

        let center = NotificationCenter.default
        let names: [Notification.Name] = [.clientDidCreate, .clientDidUpdate, .visitDidComplete, .visitDidStart, .serviceDidUpdate]
        for name in names {
            center.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.fetchClients() }
                .store(in: &cancellables)
        }

        if let eventBus {
            let stream = eventBus.stream
            eventTaskOwner.task = Task { [weak self] in
                for await event in stream {
                    if event == .refreshRequired {
                        self?.fetchClients()
                    }
                }
            }
        }
    }
    
    // MARK: - Data Fetching
    private func scheduleFetch() {
        searchTask?.cancel()
        if searchText.trimmed.isEmpty { fetchClients(); return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180)) // Debounce search
            guard !Task.isCancelled else { return }
            self?.fetchClients()
        }
    }
    
    func fetchClients() {
        searchTask?.cancel()
        refreshTask?.cancel()
        // A Load More still in flight belongs to the previous query or sort.
        // Letting it finish would append rows that don't match the new list.
        loadMoreTask?.cancel()
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoadingMore = false
        appError = nil

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let presentation = try await repository.fetchClientPresentation(query: trimmedSearch, filter: selectedFilter, sort: sortOption) {
                    guard !Task.isCancelled else { return }
                    self.inProgressClients = presentation.groups.active.compactMap { self.modelContext.model(for: $0) as? Client }
                    self.otherClients = presentation.groups.inactive.compactMap { self.modelContext.model(for: $0) as? Client }
                    self.needsAttentionClients = presentation.needsAttention.compactMap { self.modelContext.model(for: $0) as? Client }
                    self.fetchOffset = self.otherClients.count
                    self.canLoadMore = false
                    self.isLoadingMore = false
                    return
                }
                let groups = try await repository.fetchClientGroups(query: trimmedSearch)
                guard !Task.isCancelled else { return }
                var seen: Set<UUID> = []
                var inProgress = groups.active.compactMap { self.modelContext.model(for: $0) as? Client }
                    .filter { seen.insert($0.uuid).inserted }
                var others = groups.inactive.compactMap { self.modelContext.model(for: $0) as? Client }
                    .filter { seen.insert($0.uuid).inserted }

                // Apply Smart Filters
                switch selectedFilter {
                case .all:
                    break
                case .active:
                    others = [] // Handled by inProgress
                case .overdue:
                    inProgress = []
                    others = others.filter { client in
                        (client.pets ?? []).contains { $0.archivedAt == nil && $0.needsAttention }
                    }
                case .missingInfo:
                    // The same rule as the profile's "Missing:" note.
                    inProgress = inProgress.filter(ClientMissingInfo.isIncomplete)
                    others = others.filter(ClientMissingInfo.isIncomplete)
                }

                // Apply Sorting
                let sortedInProgress = sortClients(inProgress)
                let sortedOthers = sortClients(others)

                // Identify "Needs Attention" (overdue and not yet cleared by outreach).
                self.needsAttentionClients = sortedOthers.filter { client in
                    (client.pets ?? []).contains { $0.archivedAt == nil && $0.needsAttention }
                }

                self.inProgressClients = sortedInProgress
                self.otherClients = sortedOthers
                
                self.fetchOffset = self.otherClients.count
                self.canLoadMore = false
                self.isLoadingMore = false
            } catch {
                guard !Task.isCancelled else { return }
                appError = .database(error.localizedDescription)
                canLoadMore = false
                isLoadingMore = false
            }
        }
    }

    func recordAttentionOutreach(for client: Client, method: String) {
        let petsToClear = (client.pets ?? []).filter { $0.needsAttention }
        guard !petsToClear.isEmpty else { return }

        do {
            for pet in petsToClear {
                pet.recordAttentionOutreach()
            }

            try modelContext.save()
            NotificationCenter.default.post(name: .serviceDidUpdate, object: nil)
            eventBus?.publish(.refreshRequired)
            fetchClients()
            Logger.ui.info("Client list cleared needs-attention flag for \(petsToClear.count, privacy: .public) pet(s) after \(method, privacy: .public)")
        } catch {
            appError = .database(error.localizedDescription)
            Logger.database.error("Local save failed: \(error.localizedDescription, privacy: .public)")
            Logger.database.error("Failed to record client-list attention outreach: \(String(describing: error))")
        }
    }

    /// Applies a total ordering, including a UUID tie-breaker for equal names/dates.
    private func sortClients(_ clients: [Client]) -> [Client] {
        ClientListOrdering.sorted(clients, by: sortOption)
    }

    /// Waits for the fetch started by the most recent `fetchClients()` (or a
    /// filter/sort change) and any Load More. Lets tests read the lists
    /// without sleeping.
    func waitForPendingFetch() async {
        await searchTask?.value
        await refreshTask?.value
        await loadMoreTask?.value
    }

    func loadMore() {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.loadMoreOthers(query: trimmedSearch, resetOffset: false)
        }
    }

    private func loadMoreOthers(query: String, resetOffset: Bool) async {
        if isLoadingMore { return }
        if !resetOffset && !canLoadMore { return }
        isLoadingMore = true

        if resetOffset {
            fetchOffset = 0
        }

        do {
            let (pageIDs, hasMore) = try await repository.fetchInactiveClients(query: query, limit: pageSize, offset: fetchOffset)
            guard !Task.isCancelled else {
                isLoadingMore = false
                return
            }
            let newPage = pageIDs.compactMap { self.modelContext.model(for: $0) as? Client }

            if resetOffset {
                otherClients = newPage
            } else {
                var seen = Set((inProgressClients + otherClients).map(\.uuid))
                otherClients += newPage.filter { seen.insert($0.uuid).inserted }
            }

            fetchOffset += newPage.count
            canLoadMore = hasMore
            isLoadingMore = false
        } catch {
            appError = .database(error.localizedDescription)
            canLoadMore = false
            isLoadingMore = false
        }
    }

    func deleteClient(_ client: Client) {
        let clientID = client.persistentModelID
        deleteTask?.cancel()
        deleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.deleteClient(id: clientID)
                self.fetchClients()
            } catch {
                self.appError = .database(error.localizedDescription)
            }
        }
    }
}
