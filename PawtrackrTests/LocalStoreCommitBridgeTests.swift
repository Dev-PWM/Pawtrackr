import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class LocalStoreCommitBridgeTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PawtrackrSchema.models)
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    func testBackgroundSaveRefreshesExistingDirectoryAndActiveSearch() async throws {
        let container = try makeContainer()
        let bus = GlobalEventBus()
        let bridge = LocalStoreCommitBridge(container: container, eventBus: bus)
        let list = ClientsViewModel(modelContext: container.mainContext, eventBus: bus)
        list.searchText = "Alvarez"
        await list.waitForPendingFetch()
        XCTAssertTrue(list.otherClients.isEmpty)

        let delivered = expectation(description: "Committed store delivered")
        let stream = bus.stream
        let listener = Task {
            for await event in stream where event == .storeCommitted {
                delivered.fulfill()
                return
            }
        }
        defer { listener.cancel() }
        let uuid = try await Task.detached {
            let writer = ModelContext(container)
            let client = Client(firstName: "Art", lastName: "Álvarez", phone: "3236830070")
            writer.insert(client)
            try writer.save()
            return client.uuid
        }.value
        await fulfillment(of: [delivered], timeout: 3)
        await list.waitForPendingFetch()
        XCTAssertEqual(list.otherClients.map(\.uuid), [uuid])
        XCTAssertEqual(list.filterCounts[.all], 1)
        XCTAssertEqual(list.filterCounts[.missingInfo], 1)
        withExtendedLifetime(bridge) {}
    }

    func testAnotherContainerDoesNotInvalidateThisStore() async throws {
        let container = try makeContainer()
        let other = try makeContainer()
        let bus = GlobalEventBus()
        let bridge = LocalStoreCommitBridge(container: container, eventBus: bus)
        let unexpected = expectation(description: "Unrelated store ignored")
        unexpected.isInverted = true
        let stream = bus.stream
        let listener = Task {
            for await event in stream where event == .storeCommitted { unexpected.fulfill() }
        }
        defer { listener.cancel() }
        try await Task.detached {
            let writer = ModelContext(other)
            writer.insert(Client(firstName: "Other", lastName: "Store"))
            try writer.save()
        }.value
        await fulfillment(of: [unexpected], timeout: 0.2)
        withExtendedLifetime(bridge) {}
    }

    func testBackgroundPetEditRefreshesMaterializedClientGraph() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let client = Client(firstName: "Owner", lastName: "Live")
        let pet = Pet(name: "Buddy", species: .dog)
        context.insert(client)
        context.insert(pet)
        pet.owner = client
        try context.save()
        let petUUID = pet.uuid
        let bus = GlobalEventBus()
        let bridge = LocalStoreCommitBridge(container: container, eventBus: bus)
        let detail = ClientDetailViewModel(client: client, modelContext: context, eventBus: bus)
        XCTAssertEqual(detail.pets.first?.name, "Buddy")
        let delivered = expectation(description: "Pet graph invalidated")
        let stream = bus.stream
        let listener = Task {
            for await event in stream where event == .storeCommitted {
                delivered.fulfill()
                return
            }
        }
        defer { listener.cancel() }
        try await Task.detached {
            let writer = ModelContext(container)
            let stored = try XCTUnwrap(writer.fetch(FetchDescriptor<Pet>(predicate: #Predicate { $0.uuid == petUUID })).first)
            stored.name = "Buddy Updated"
            stored.behaviorTags = ["nervous", "special_needs"]
            try writer.save()
        }.value
        await fulfillment(of: [delivered], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while detail.pets.first?.name != "Buddy Updated", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(detail.pets.first?.name, "Buddy Updated")
        XCTAssertEqual(detail.pets.first?.behaviorTags, ["nervous", "special_needs"])
        XCTAssertGreaterThan(detail.petPresentationRevision, 1)
        withExtendedLifetime(bridge) {}
    }

    func testLargeBackgroundIntakeRefreshesAll2500ClientsWithoutRecreatingList() async throws {
        let container = try makeContainer()
        let bus = GlobalEventBus()
        let bridge = LocalStoreCommitBridge(container: container, eventBus: bus)
        let list = ClientsViewModel(modelContext: container.mainContext, eventBus: bus)
        await list.waitForPendingFetch()
        let delivered = expectation(description: "Large intake invalidated")
        let stream = bus.stream
        let listener = Task {
            for await event in stream where event == .storeCommitted {
                delivered.fulfill()
                return
            }
        }
        defer { listener.cancel() }
        try await Task.detached {
            let writer = ModelContext(container)
            for index in 0..<2500 {
                writer.insert(Client(firstName: "Client", lastName: String(format: "%04d", index)))
            }
            try writer.save()
        }.value
        await fulfillment(of: [delivered], timeout: 5)
        await list.waitForPendingFetch()
        XCTAssertEqual(list.otherClients.count, 2500)
        XCTAssertEqual(Set(list.otherClients.map(\.uuid)).count, 2500)
        XCTAssertEqual(list.filterCounts[.all], 2500)
        XCTAssertEqual(list.otherClients.first?.lastName, "0000")
        XCTAssertEqual(list.otherClients.last?.lastName, "2499")
        withExtendedLifetime(bridge) {}
    }
}
