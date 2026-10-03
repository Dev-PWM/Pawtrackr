//
//  ClientRepository.swift
//  Pawtrackr
//
//  Elite background actor for Client data operations.
//  Ensures that large dataset searches and filtering never hitch the main thread.
//

import Foundation
import SwiftData
import OSLog

private let clientRepoLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "ClientRepository")

struct NewPetData: Sendable {
    let name: String
    let species: Species
    let gender: PetGender
    let breed: String?
    let color: String?
    let photoData: Data?
    let health: String?
    let behaviorTags: [String]
    let birthdate: Date?
}

struct NewContactData: Sendable {
    let name: String
    let relation: String?
    let phone: String
}

protocol ClientRepositoryProtocol: Sendable {
    func fetchClients(query: String, limit: Int, offset: Int) async throws -> [PersistentIdentifier]
    func fetchActiveClients(query: String) async throws -> [PersistentIdentifier]
    func fetchInactiveClients(query: String, limit: Int, offset: Int) async throws -> ([PersistentIdentifier], Bool)
    func findClient(byPhone phone: String) async throws -> PersistentIdentifier?
    func findDuplicateClient(firstName: String, lastName: String, phone: String) async throws -> ClientDuplicateMatch?
    func fetchClientGroups(query: String) async throws -> ClientListGroups
    func fetchClientPresentation(query: String, filter: ClientsViewModel.Filter, sort: ClientsViewModel.SortOption) async throws -> ClientListPresentation?
    func createClient(
        firstName: String,
        lastName: String,
        phone: String,
        email: String,
        address: String,
        photoData: Data?,
        pets: [NewPetData],
        contacts: [NewContactData]
    ) async throws -> PersistentIdentifier
    func saveClient(id: PersistentIdentifier, firstName: String, lastName: String, phone: String, email: String) async throws
    func deleteClient(id: PersistentIdentifier) async throws
}

struct ClientListGroups: Sendable {
    let active: [PersistentIdentifier]
    let inactive: [PersistentIdentifier]
}

struct ClientListPresentation: Sendable {
    let groups: ClientListGroups
    let needsAttention: [PersistentIdentifier]
}

extension ClientRepositoryProtocol {
    /// Custom repositories can retain the model-based presentation fallback.
    func fetchClientPresentation(query: String, filter: ClientsViewModel.Filter, sort: ClientsViewModel.SortOption) async throws -> ClientListPresentation? { nil }

    /// Keeps test/custom repositories compatible while the production store uses indexed names.
    func findDuplicateClient(firstName: String, lastName: String, phone: String) async throws -> ClientDuplicateMatch? {
        guard !phone.isEmpty, let id = try await findClient(byPhone: phone) else { return nil }
        return ClientDuplicateMatch(id: id, reason: .phone)
    }

    /// Collects a full list for repositories that expose only the original paged interface.
    func fetchClientGroups(query: String) async throws -> ClientListGroups {
        let active = try await fetchActiveClients(query: query)
        var inactive: [PersistentIdentifier] = []
        var more = true
        while more {
            let page = try await fetchInactiveClients(query: query, limit: 1000, offset: inactive.count)
            try Task.checkCancellation()
            inactive += page.0
            more = page.1 && !page.0.isEmpty
        }
        return ClientListGroups(active: active, inactive: inactive)
    }
}

@ModelActor
final actor ClientRepository: ClientRepositoryProtocol {

    private var cachedSearchBook: (revision: UInt64, locale: String, book: ClientSearchBook)?

    /// Loads a consistent value snapshot; any completed local save invalidates it.
    private func searchBook() async throws -> ClientSearchBook {
        while true {
            try Task.checkCancellation()
            let revision = ClientStoreRevision.shared.current
            let locale = Locale.current.identifier
            if let cachedSearchBook, cachedSearchBook.revision == revision, cachedSearchBook.locale == locale {
                return cachedSearchBook.book
            }
            let book = try await ClientBackgroundQuery.run(container: modelContainer) { context in
                let activeIDs = try Self.activeClientIDs(in: context)
                var descriptor = FetchDescriptor<Client>(sortBy: [SortDescriptor(\.lastName), SortDescriptor(\.firstName)])
                descriptor.relationshipKeyPathsForPrefetching = [\Client.pets]
                var records: [ClientSearchRecord] = []
                for (index, client) in try context.fetch(descriptor).enumerated() {
                    if index.isMultiple(of: 128) { try Task.checkCancellation() }
                    records.append(ClientSearchRecord(client))
                }
                return ClientSearchBook(records: records, activeIDs: activeIDs)
            }
            guard ClientStoreRevision.shared.current == revision, Locale.current.identifier == locale else { continue }
            cachedSearchBook = (revision, locale, book)
            return book
        }
    }

    /// Matches the full value snapshot before paging; there is no candidate cap.
    func fetchClients(query: String, limit: Int, offset: Int) async throws -> [PersistentIdentifier] {
        guard limit > 0 else { return [] }
        let search = ClientSearchQuery(query)
        let book = try await searchBook()
        return try await ClientBackgroundQuery.values {
            var matches: [PersistentIdentifier] = []
            for (index, record) in book.records.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                if search.matches(record) { matches.append(record.id) }
            }
            return Array(matches.dropFirst(max(0, offset)).prefix(limit))
        }
    }

    /// Gets all matching active/inactive owners from one snapshot and one candidate pass.
    func fetchClientGroups(query: String) async throws -> ClientListGroups {
        let search = ClientSearchQuery(query)
        let book = try await searchBook()
        return try await ClientBackgroundQuery.values {
            var active: [PersistentIdentifier] = []
            var inactive: [PersistentIdentifier] = []
            for (index, record) in book.records.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                guard search.matches(record) else { continue }
                if book.activeIDs.contains(record.id) { active.append(record.id) }
                else { inactive.append(record.id) }
            }
            return ClientListGroups(active: active, inactive: inactive)
        }
    }

    /// Filters, deduplicates and sorts value records before the UI hydrates models.
    func fetchClientPresentation(query: String, filter: ClientsViewModel.Filter, sort: ClientsViewModel.SortOption) async throws -> ClientListPresentation? {
        let search = ClientSearchQuery(query)
        let book = try await searchBook()
        return try await ClientBackgroundQuery.values {
            let now = Date()
            var seen: Set<UUID> = []
            var active: [ClientSearchRecord] = []
            var inactive: [ClientSearchRecord] = []
            for (index, record) in book.records.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                guard search.matches(record), seen.insert(record.ordering.uuid).inserted else { continue }
                let isActive = book.activeIDs.contains(record.id)
                let attention = record.attentionDueAt.map { now > $0 } ?? false
                switch filter {
                case .all: break
                case .active: guard isActive else { continue }
                case .overdue: guard !isActive && attention else { continue }
                case .missingInfo: guard record.incomplete else { continue }
                }
                if isActive { active.append(record) } else { inactive.append(record) }
            }
            let orderedActive = active.sorted { ClientListOrdering.precedes($0.ordering, $1.ordering, by: sort) }
            let orderedInactive = inactive.sorted { ClientListOrdering.precedes($0.ordering, $1.ordering, by: sort) }
            let attention = orderedInactive.filter { $0.attentionDueAt.map { now > $0 } ?? false }.map(\.id)
            return ClientListPresentation(groups: ClientListGroups(active: orderedActive.map(\.id), inactive: orderedInactive.map(\.id)), needsAttention: attention)
        }
    }

    /// Returns every active owner, without truncating sessions at an arbitrary limit.
    private static func activeClientIDs(in context: ModelContext) throws -> Set<PersistentIdentifier> {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.endedAt == nil })
        descriptor.relationshipKeyPathsForPrefetching = [\Visit.pet]
        return Set(try context.fetch(descriptor).compactMap { $0.pet?.owner?.persistentModelID })
    }

    /// Retains the original repository interface for callers needing only the active group.
    func fetchActiveClients(query: String) async throws -> [PersistentIdentifier] {
        try await fetchClientGroups(query: query).active
    }

    /// Pages only after active-owner exclusion and strict multi-field matching.
    func fetchInactiveClients(query: String, limit: Int, offset: Int) async throws -> ([PersistentIdentifier], Bool) {
        let ids = try await fetchClientGroups(query: query).inactive
        let start = min(max(0, offset), ids.count)
        let page = Array(ids.dropFirst(start).prefix(max(0, limit)))
        return (page, start + page.count < ids.count)
    }

    /// Looks up a phone using its indexed digit-only key, including legacy formatted numbers.
    func findClient(byPhone phone: String) async throws -> PersistentIdentifier? {
        try await ClientCreationCoordinator.shared.prepare(container: modelContainer)
        let digits = PhoneUtils.searchKey(phone)
        guard !digits.isEmpty else { return nil }
        return try await ClientBackgroundQuery.run(container: modelContainer) { context in
            var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.phoneDigits == digits })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.persistentModelID
        }
    }

    /// Performs the same duplicate lookup used inside the final creation transaction.
    func findDuplicateClient(firstName: String, lastName: String, phone: String) async throws -> ClientDuplicateMatch? {
        try await ClientCreationCoordinator.shared.prepare(container: modelContainer)
        return try await ClientBackgroundQuery.run(container: modelContainer) { context in
            try ClientDuplicateLookup.find(in: context, firstName: firstName, lastName: lastName, phone: phone)
        }
    }

    func createClient(
        firstName: String,
        lastName: String,
        phone: String,
        email: String,
        address: String,
        photoData: Data?,
        pets: [NewPetData],
        contacts: [NewContactData]
    ) async throws -> PersistentIdentifier {
        try await ClientCreationCoordinator.shared.create(container: modelContainer, input: ClientCreationInput(
            firstName: firstName, lastName: lastName, phone: phone, email: email, address: address,
            photoData: photoData, pets: pets, contacts: contacts
        ))
    }

    func saveClient(id: PersistentIdentifier, firstName: String, lastName: String, phone: String, email: String) async throws {
        guard let client = modelContext.model(for: id) as? Client else { return }
        client.setFirstName(firstName)
        client.setLastName(lastName)
        client.setPhone(phone)
        client.setEmail(email)
        try modelContext.save()
    }

    func deleteClient(id: PersistentIdentifier) async throws {
        guard let client = modelContext.model(for: id) as? Client else { return }
        let clientUUID = client.uuid
        
        let pets = Array(client.pets ?? [])
        let petUUIDs = pets.map(\.uuid)
        let visits = pets.flatMap { pet in Array(pet.visits ?? []) }
        let paymentDates = visits.compactMap { $0.payment?.paidAt }
        let visitActivityDates = visits.map { $0.endedAt ?? $0.startedAt }

        modelContext.delete(client)
        try modelContext.save()
        SpotlightIndexer.shared.removeClientAndPetsFromIndex(clientID: clientUUID, petIDs: petUUIDs)

        let cal = Calendar.current
        var affectedDays: Set<Date> = []
        for date in paymentDates { affectedDays.insert(cal.startOfDay(for: date)) }
        for date in visitActivityDates { affectedDays.insert(cal.startOfDay(for: date)) }
        for day in affectedDays {
            SummaryUpdater.rebuildDay(for: day, in: modelContext)
        }
    }
}
