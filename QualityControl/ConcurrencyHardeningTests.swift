import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class ConcurrencyHardeningTests: XCTestCase {
    func testThousandInsertsDuringSearchAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(PawtrackrSchema.models)
        let config = LocalStoreConfiguration.make(schema: schema, url: root.appendingPathComponent("Chaos.store"))
        let container = try ModelContainer(for: schema, configurations: [config])
        let writer = await Task.detached { ChaosClientWriter(modelContainer: container) }.value
        let reader = ClientRepository(modelContainer: container)
        let deletedIDs = try await writer.insert(prefix: "Delete", start: 0, count: 40)
        let insertTask = Task.detached {
            for batch in 0..<40 {
                _ = try await writer.insert(prefix: "Insert", start: batch * 25, count: 25)
                await Task.yield()
            }
        }
        let deleteTask = Task.detached {
            // Independent actor/context, with disjoint records from the insert stream.
            let deleter = ClientRepository(modelContainer: container)
            for id in deletedIDs { try await deleter.deleteClient(id: id) }
        }
        for _ in 0..<30 {
            let result = try await reader.fetchClientGroups(query: "insert")
            XCTAssertEqual(Set(result.inactive).count, result.inactive.count)
            await Task.yield()
        }
        try await insertTask.value
        try await deleteTask.value
        let result = try await reader.fetchClientGroups(query: "")
        XCTAssertEqual(result.inactive.count, 1_000)
        let counts = try await ClientBackgroundQuery.run(container: container) { context in
            (try context.fetchCount(FetchDescriptor<Client>()), Thread.isMainThread)
        }
        XCTAssertEqual(counts.0, 1_000)
        XCTAssertFalse(counts.1)
    }

    func testSixtySixKeystrokesCoalesceIntoAtMostThreeQueries() async throws {
        let dataStore = DataStoreService(inMemory: true)
        let repository = CountingClientRepository()
        let vm = ClientsViewModel(modelContext: dataStore.container.mainContext, repository: repository)
        await vm.waitForPendingFetch()
        await repository.resetCount()
        for index in 0..<66 {
            vm.searchText = "search \(index)"
            try await Task.sleep(for: .milliseconds(15))
        }
        await vm.waitForPendingFetch()
        let count = await repository.queryCount
        let query = await repository.lastQuery
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(count, 3)
        XCTAssertEqual(query, "search 65")
    }
}

@ModelActor
private actor ChaosClientWriter {
    /// Writes a bounded batch on its own executor and returns only persistent identifiers.
    func insert(prefix: String, start: Int, count: Int) throws -> [PersistentIdentifier] {
        let clients = (start..<(start + count)).map { Client(firstName: prefix, lastName: "Fictional \($0)") }
        for client in clients { modelContext.insert(client) }
        try modelContext.save()
        return clients.map(\.persistentModelID)
    }
}

private actor CountingClientRepository: ClientRepositoryProtocol {
    private(set) var queryCount = 0
    private(set) var lastQuery = ""
    func resetCount() { queryCount = 0 }
    func fetchClientPresentation(query: String, filter: ClientsViewModel.Filter, sort: ClientsViewModel.SortOption) async throws -> ClientListPresentation? {
        queryCount += 1; lastQuery = query
        return ClientListPresentation(groups: ClientListGroups(active: [], inactive: []), needsAttention: [])
    }
    func fetchClients(query: String, limit: Int, offset: Int) async throws -> [PersistentIdentifier] { [] }
    func fetchActiveClients(query: String) async throws -> [PersistentIdentifier] { [] }
    func fetchInactiveClients(query: String, limit: Int, offset: Int) async throws -> ([PersistentIdentifier], Bool) { ([], false) }
    func findClient(byPhone phone: String) async throws -> PersistentIdentifier? { nil }
    func createClient(firstName: String, lastName: String, phone: String, email: String, address: String, photoData: Data?, pets: [NewPetData], contacts: [NewContactData]) async throws -> PersistentIdentifier { throw AppError.database("Unsupported in counting test") }
    func saveClient(id: PersistentIdentifier, firstName: String, lastName: String, phone: String, email: String) async throws {}
    func deleteClient(id: PersistentIdentifier) async throws {}
}
