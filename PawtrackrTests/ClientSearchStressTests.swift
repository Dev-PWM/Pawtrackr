import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class ClientSearchStressTests: XCTestCase {
    private var container: ModelContainer!
    private var seeded: [ClientSearchStressFixture.Seeded] = []

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema(PawtrackrSchema.models)
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        seeded = try await ClientSearchStressFixture.seed(in: container)
    }

    override func tearDown() async throws {
        seeded = []
        container = nil
        try await super.tearDown()
    }

    func testEveryOrdinaryOwnerIsFoundInBothNameOrdersAndByTheirDogAndPhone() async throws {
        XCTAssertEqual(seeded.count, 1000)
        XCTAssertEqual(Set(seeded.map { $0.entry.fullName }).count, 1000)
        let dogs = try container.mainContext.fetch(FetchDescriptor<Pet>())
        XCTAssertEqual(dogs.count, 1000)
        XCTAssertTrue(dogs.allSatisfy { $0.species == .dog && $0.owner != nil })
        XCTAssertEqual(dogs.filter { $0.gender == .female }.count, 500)
        XCTAssertEqual(dogs.filter { $0.gender == .male }.count, 500)
        for row in seeded {
            for name in [row.entry.first, row.entry.last, row.entry.dog] {
                XCTAssertTrue(name.allSatisfy { $0.isASCII && $0.isLetter }, name)
            }
        }
        let repository = ClientRepository(modelContainer: container)
        var wordIndex: [String: Set<PersistentIdentifier>] = [:]
        for row in seeded {
            let words = "\(row.entry.fullName) \(row.entry.dog) \(row.entry.breed)".lowercased().split(separator: " ")
            for word in words { wordIndex[String(word), default: []].insert(row.id) }
        }
        var elapsed: [Double] = []
        for row in seeded {
            let entry = row.entry
            let phone = entry.phone
            let formatted = "+1 (\(phone.prefix(3))) \(phone.dropFirst(3).prefix(3))-\(phone.suffix(4))"
            let queries = [entry.fullName, "\(entry.last) \(entry.first)", entry.fullName.uppercased(),
                           "\(entry.last) \(entry.dog) \(entry.first)", "\(entry.first) \(entry.last) \(entry.breed)"]
            for query in queries {
                let expected = query.lowercased().split(separator: " ").map { term in
                    wordIndex.filter { $0.key.hasPrefix(term) }.values.reduce(into: Set<PersistentIdentifier>()) {
                        $0.formUnion($1)
                    }
                }.reduce(Set(seeded.map(\.id))) { $0.intersection($1) }
                let start = ContinuousClock.now
                let results = try await repository.fetchClientGroups(query: query)
                elapsed.append(seconds(start.duration(to: .now)))
                XCTAssertTrue(expected.contains(row.id), query)
                XCTAssertTrue(Set(results.active + results.inactive) == expected, "Wrong result set for \(query)")
            }
            for query in [phone, formatted] {
                let start = ContinuousClock.now
                let results = try await repository.fetchClientGroups(query: query)
                elapsed.append(seconds(start.duration(to: .now)))
                XCTAssertEqual(Set(results.active + results.inactive), [row.id], query)
            }
        }
        let ordered = elapsed.sorted()
        let summary = "1000 alphabetic owners and dogs; \(elapsed.count) exact-result probes; "
            + "warm p50 \(ordered[ordered.count / 2])s; p95 \(ordered[ordered.count * 95 / 100])s; "
            + "maximum including cold fetch \(ordered.last ?? 0)s"
        let attachment = XCTAttachment(string: summary)
        attachment.name = "Ordinary names search stress measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSharedNamesDogsBreedsAndPartialPhonesReturnEveryMatchingOwner() async throws {
        let repository = ClientRepository(modelContainer: container)
        let queries = ["Ava", "Martinez", "Zoe", "Zimmerman", "Luna", "Cooper", "Oliver", "Golden Retriever",
                       "202", "55501", "0099", "Ava Luna", "Martinez Poodle", "Zoe Zimmerman", "av mart",
                       "Milo 202", "Ava Missing", "9999999999", "Zoe Adams Willow"]
        for query in queries {
            let expected = Set(seeded.filter { oracle(query, entry: $0.entry) }.map(\.id))
            for sort in ClientsViewModel.SortOption.allCases {
                let presentation = try await repository.fetchClientPresentation(query: query, filter: .all, sort: sort)
                let result = try XCTUnwrap(presentation)
                let actual = result.groups.active + result.groups.inactive
                XCTAssertTrue(Set(actual) == expected, "Wrong result set for \(query) / \(sort)")
                XCTAssertEqual(actual.count, expected.count, "No duplicate cards: \(query)")
                XCTAssertEqual(result.filterCounts[.all, default: 0], expected.count)
            }
        }
    }

    func testCountryPrefixAndExtensionStaySearchableWhileTypingAndCombiningNames() async throws {
        let repository = ClientRepository(modelContainer: container)
        let row = try XCTUnwrap(seeded.first { $0.entry.fullName == "Ava Martinez" })
        for query in ["1 (202)", "1 202 555", "+1 (202)"] {
            let result = try await repository.fetchClientGroups(query: query)
            XCTAssertTrue(Set(result.active + result.inactive) == Set(seeded.map(\.id)), query)
        }
        for query in ["\(row.entry.phone) ext 42 Ava", "Ava \(row.entry.phone) x42 Martinez",
                      "\(row.entry.phone), ext. 42 Ava", "\(row.entry.phone), x42 Martinez",
                      "\(row.entry.phone) extension 42 Martinez Ava"] {
            let result = try await repository.fetchClientGroups(query: query)
            XCTAssertEqual(Set(result.active + result.inactive), [row.id], query)
        }
        for query in ["1202", "202555001 x42 Ava", "+1 202555001 x42 Ava", "1 (202) 555-001 ext. 42 Ava",
                      "\(row.entry.phone), ext. 42 Missing", "20255500188"] {
            let result = try await repository.fetchClientGroups(query: query)
            XCTAssertTrue(result.active.isEmpty && result.inactive.isEmpty, query)
        }
    }

    func testSearchAndSmartFiltersKeepCorrectCountsAndGroupMembership() async throws {
        let repository = ClientRepository(modelContainer: container)
        for query in ["", "Ava", "Luna", "Milo", "202", "Zimmerman"] {
            let matching = seeded.filter { oracle(query, entry: $0.entry) }
            for filter in ClientsViewModel.Filter.allCases {
                let expected = matching.filter { row in
                    switch filter {
                    case .all: true
                    case .active: row.entry.active
                    case .missingInfo: row.entry.missingContact
                    case .overdue: false
                    }
                }
                for sort in [ClientsViewModel.SortOption.lastName, .firstName] {
                    let presentation = try await repository.fetchClientPresentation(
                        query: query, filter: filter, sort: sort
                    )
                    let result = try XCTUnwrap(presentation)
                    XCTAssertTrue(Set(result.groups.active) == Set(expected.filter { $0.entry.active }.map(\.id)))
                    XCTAssertTrue(Set(result.groups.inactive) == Set(expected.filter { !$0.entry.active }.map(\.id)))
                    XCTAssertEqual(result.filterCounts[.all, default: 0], matching.count)
                    XCTAssertEqual(result.filterCounts[.active, default: 0], matching.filter { $0.entry.active }.count)
                    XCTAssertEqual(result.filterCounts[.missingInfo, default: 0],
                                   matching.filter { $0.entry.missingContact }.count)
                    XCTAssertEqual(result.filterCounts[.overdue, default: 0], 0)
                }
            }
        }
    }

    func testNewClientAppearsInAnExistingDogSearchAndClearingRestoresTheWholeBook() async throws {
        let bus = GlobalEventBus()
        let bridge = LocalStoreCommitBridge(container: container, eventBus: bus)
        let list = ClientsViewModel(modelContext: container.mainContext, eventBus: bus)
        await list.waitForPendingFetch()
        XCTAssertEqual(list.inProgressClients.count + list.otherClients.count, 1000)
        list.searchText = "Pepper"
        await list.waitForPendingFetch()
        XCTAssertTrue(list.inProgressClients.isEmpty && list.otherClients.isEmpty)
        let form = NewClientViewModel(modelContext: container.mainContext)
        form.first = "Clara"
        form.last = "Watson"
        form.phone = "2025558000"
        form.contacts = []
        form.pets[0].name = "Pepper"
        form.pets[0].gender = .female
        form.pets[0].breed = "Corgi"
        let outcome = await form.createClient()
        XCTAssertEqual(outcome, .created)
        await eventually { list.otherClients.count == 1 }
        XCTAssertEqual(list.otherClients.first?.fullName, "Clara Watson")
        XCTAssertEqual(list.otherClients.first?.pets?.first?.name, "Pepper")
        XCTAssertEqual(list.otherClients.first?.pets?.first?.gender, .female)
        XCTAssertEqual(list.searchText, "Pepper")
        list.searchText = ""
        await list.waitForPendingFetch()
        XCTAssertEqual(list.inProgressClients.count + list.otherClients.count, 1001)
        XCTAssertEqual(Set((list.inProgressClients + list.otherClients).map(\.uuid)).count, 1001)
        withExtendedLifetime(bridge) {}
    }

    func testAnOldSearchCannotPublishDuringTheNextTypingDebounce() async throws {
        let repository = DelayedClientSearchRepository(container: container)
        let list = ClientsViewModel(modelContext: container.mainContext, repository: repository)
        await list.waitForPendingFetch()
        list.searchText = "Ava"
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await repository.isHeld), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await repository.isHeld
        XCTAssertTrue(held)
        list.searchText = "Zoe"
        await repository.release()
        // The prior query completes before the new query's 300ms typing delay.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(list.inProgressClients.count + list.otherClients.count, 1000,
                       "An obsolete Ava response must not replace the list while Zoe is being typed.")
        await list.waitForPendingFetch()
        XCTAssertEqual(list.inProgressClients.count + list.otherClients.count, 25)
        XCTAssertTrue((list.inProgressClients + list.otherClients).allSatisfy { $0.firstName == "Zoe" })
    }

    func testConcurrentIntakeAndRapidFilterChangesKeepEveryClientAndUnsavedEdits() async throws {
        let bus = GlobalEventBus()
        let bridge = LocalStoreCommitBridge(container: container, eventBus: bus)
        let list = ClientsViewModel(modelContext: container.mainContext, eventBus: bus)
        await list.waitForPendingFetch()
        let source = try XCTUnwrap(container.mainContext.model(for: seeded[0].id) as? Client)
        source.notes = "Keep this unsaved note"
        let repository = ClientRepository(modelContainer: container)
        let names = ["Clara", "Hazel", "Iris", "Nathan", "Peter"]
        let surnames = ["Watson", "Woods", "Turner", "Young"]
        let writer = Task {
            try await withThrowingTaskGroup(of: PersistentIdentifier.self) { group in
                for (index, pair) in names.flatMap({ first in surnames.map { (first, $0) } }).enumerated() {
                    group.addTask {
                        try await repository.createClient(firstName: pair.0, lastName: pair.1,
                            phone: "202555" + String(format: "%04d", 8000 + index), email: "", address: "",
                            photoData: nil, pets: [], contacts: [])
                    }
                }
                var ids: [PersistentIdentifier] = []
                for try await id in group { ids.append(id) }
                return ids
            }
        }
        for index in 0..<30 {
            list.searchText = ["Ava", "Luna", "Zoe", "Clara", ""][index % 5]
            list.sortOption = ClientsViewModel.SortOption.allCases[index % 5]
            list.selectedFilter = index.isMultiple(of: 2) ? .active : .all
            await Task.yield()
        }
        let created = try await writer.value
        XCTAssertEqual(Set(created).count, 20)
        list.searchText = "Clara"
        list.sortOption = .lastName
        list.selectedFilter = .all
        await eventually { list.otherClients.count == 4 }
        XCTAssertEqual(list.otherClients.map(\.lastName), ["Turner", "Watson", "Woods", "Young"])
        XCTAssertEqual(list.searchText, "Clara")
        XCTAssertEqual(list.sortOption, .lastName)
        XCTAssertEqual(list.selectedFilter, .all)
        list.searchText = ""
        await list.waitForPendingFetch()
        await eventually { list.inProgressClients.count + list.otherClients.count == 1020 }
        XCTAssertEqual(Set((list.inProgressClients + list.otherClients).map(\.uuid)).count, 1020)
        XCTAssertEqual(list.inProgressClients.count, 100)
        XCTAssertEqual(source.notes, "Keep this unsaved note")
        XCTAssertTrue(container.mainContext.hasChanges, "Refreshing must not save or discard unrelated edits.")
        XCTAssertNil(list.appError)
        withExtendedLifetime(bridge) {}
    }

    /// Independent oracle for this fixture's plain alphabetic words and digit-only phones.
    private func oracle(_ query: String, entry: ClientSearchStressFixture.Entry) -> Bool {
        let words = "\(entry.first) \(entry.last) \(entry.dog) \(entry.breed)".lowercased().split(separator: " ")
        return query.lowercased().split(separator: " ").allSatisfy { term in
            if term.allSatisfy(\.isNumber) { return entry.phone.contains(term) }
            return words.contains { $0.hasPrefix(term) }
        }
    }

    /// Converts elapsed clock time for the exported latency measurements.
    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Waits for asynchronous commit delivery without forcing a manual list refresh.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Committed data must reach the existing client list", file: file, line: line)
    }
}

/// Holds a genuine background snapshot so obsolete completion is reproducible without slowing storage.
private actor DelayedClientSearchRepository: ClientRepositoryProtocol {
    let base: ClientRepository
    private(set) var isHeld = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(container: ModelContainer) { base = ClientRepository(modelContainer: container) }

    func release() { continuation?.resume(); continuation = nil }

    func fetchClientPresentation(query: String, filter: ClientsViewModel.Filter,
                                 sort: ClientsViewModel.SortOption) async throws -> ClientListPresentation? {
        let result = try await base.fetchClientPresentation(query: query, filter: filter, sort: sort)
        if query == "Ava", !isHeld {
            await withCheckedContinuation { continuation = $0; isHeld = true }
        }
        return result
    }

    func fetchClients(query: String, limit: Int, offset: Int) async throws -> [PersistentIdentifier] {
        try await base.fetchClients(query: query, limit: limit, offset: offset)
    }
    func fetchActiveClients(query: String) async throws -> [PersistentIdentifier] {
        try await base.fetchActiveClients(query: query)
    }
    func fetchInactiveClients(query: String, limit: Int, offset: Int) async throws -> ([PersistentIdentifier], Bool) {
        try await base.fetchInactiveClients(query: query, limit: limit, offset: offset)
    }
    func findClient(byPhone phone: String) async throws -> PersistentIdentifier? {
        try await base.findClient(byPhone: phone)
    }
    // swiftlint:disable:next function_parameter_count
    func createClient(firstName: String, lastName: String, phone: String, email: String, address: String,
                      photoData: Data?, pets: [NewPetData],
                      contacts: [NewContactData]) async throws -> PersistentIdentifier {
        try await base.createClient(firstName: firstName, lastName: lastName, phone: phone, email: email,
                                    address: address, photoData: photoData, pets: pets, contacts: contacts)
    }
    func saveClient(id: PersistentIdentifier, firstName: String, lastName: String,
                    phone: String, email: String) async throws {
        try await base.saveClient(id: id, firstName: firstName, lastName: lastName, phone: phone, email: email)
    }
    func deleteClient(id: PersistentIdentifier) async throws { try await base.deleteClient(id: id) }
}
