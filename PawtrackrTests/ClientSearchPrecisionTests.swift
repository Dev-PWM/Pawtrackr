import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class ClientSearchPrecisionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        context = container.mainContext
    }

    func testPhoneKeyIsPersistedAndUpdatedWithoutCountryCodeOrExtension() throws {
        let client = Client(firstName: "José", lastName: "Peña", phone: "+13235550199")
        context.insert(client)
        try context.save()
        XCTAssertEqual(client.phoneDigits, "3235550199")
        client.setPhone("(626) 555-0123 x42")
        try context.save()
        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(fresh.model(for: client.persistentModelID) as? Client)
        XCTAssertEqual(stored.phoneDigits, "6265550123")
        XCTAssertEqual(stored.phone, "+16265550123")
        client.setPhone(nil)
        XCTAssertEqual(client.phoneDigits, "")
    }

    func testLegacyKeyBackfillPreservesClientValuesAndTimestamps() async throws {
        let client = Client(firstName: "  José ", lastName: "Peña", phone: "(323) 555-0199")
        client.phoneDigits = ""; client.normalizedNameKey = ""; client.searchKeysVersion = 0
        client.notes = "Keep this note"
        context.insert(client)
        try context.save()
        let before = client.updatedAt
        let id = try await ClientRepository(modelContainer: container).findClient(byPhone: "+13235550199")
        XCTAssertEqual(id, client.persistentModelID)
        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(fresh.model(for: client.persistentModelID) as? Client)
        XCTAssertEqual(stored.phone, "(323) 555-0199")
        XCTAssertEqual(stored.phoneDigits, "3235550199")
        XCTAssertEqual(stored.normalizedNameKey, "jose pena")
        XCTAssertEqual(stored.updatedAt, before)
        XCTAssertEqual(stored.notes, "Keep this note")
    }

    func testFullNameDuplicateWithoutPhoneKeepsTheFormAndExistingClient() async throws {
        let existing = Client(firstName: "José", lastName: "Peña")
        context.insert(existing); try context.save()
        let vm = NewClientViewModel(modelContext: context)
        vm.first = "  JOSE "; vm.last = "PENA"
        let outcome = await vm.createClient()
        XCTAssertEqual(outcome, .duplicateFound)
        XCTAssertEqual(vm.duplicateClientID, existing.persistentModelID)
        XCTAssertNil(vm.createdClientID)
        XCTAssertNotNil(vm.validationError(for: .first))
        XCTAssertNotNil(vm.validationError(for: .last))
        XCTAssertNil(vm.validationError(for: .phone))
        XCTAssertEqual(vm.first, "  JOSE ")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Client>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppNotification>()), 0)
    }

    func testIdenticalFullNameWithDifferentPhoneIsStillBlocked() async throws {
        let existing = Client(firstName: "José", lastName: "Peña", phone: "+13235550199")
        context.insert(existing); try context.save()
        let vm = NewClientViewModel(modelContext: context)
        vm.first = "JOSE"; vm.last = "PENA"; vm.phone = "(626) 555-0123"
        let outcome = await vm.createClient()
        XCTAssertEqual(outcome, .duplicateFound, "The requested rule blocks matching phone OR identical full name.")
        XCTAssertEqual(vm.duplicateClientID, existing.persistentModelID)
        XCTAssertNotNil(vm.validationError(for: .first))
        XCTAssertNil(vm.validationError(for: .phone))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Client>()), 1)
    }

    func testSharedLastNameAndDifferentPhoneAreNotDuplicates() async throws {
        context.insert(Client(firstName: "José", lastName: "Peña", phone: "+13235550199"))
        try context.save()
        let vm = NewClientViewModel(modelContext: context)
        vm.first = "Ana"; vm.last = "Peña"; vm.phone = "(626) 555-0123"
        let outcome = await vm.createClient()
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Client>()), 2)
    }

    func testMatchingPhoneWithDifferentNameIsBlockedBeforeSave() async throws {
        let existing = Client(firstName: "José", lastName: "Peña", phone: "(323) 555-0199")
        context.insert(existing); try context.save()
        let vm = NewClientViewModel(modelContext: context)
        vm.first = "Ana"; vm.last = "Smith"; vm.phone = "+1 323 555 0199"
        let outcome = await vm.createClient()
        XCTAssertEqual(outcome, .duplicateFound)
        XCTAssertEqual(vm.duplicateClientID, existing.persistentModelID)
        XCTAssertNotNil(vm.validationError(for: .phone))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Client>()), 1)
    }

    func testTwoIndependentCreatorsCannotPersistTheSameOwner() async throws {
        let first = ClientRepository(modelContainer: container)
        let second = ClientRepository(modelContainer: container)
        let outcomes = await withTaskGroup(of: String.self) { group in
            for repository in [first, second] {
                group.addTask {
                    do {
                        _ = try await repository.createClient(firstName: "José", lastName: "Peña", phone: "(323) 555-0199", email: "", address: "", photoData: nil, pets: [], contacts: [])
                        return "created"
                    } catch is ClientDuplicateError { return "duplicate" }
                    catch { return "unexpected: \(error)" }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values.sorted()
        }
        XCTAssertEqual(outcomes, ["created", "duplicate"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Client>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppNotification>()), 1)
    }

    func testFormattedPhoneFragmentsCannotMatchDisconnectedDigits() {
        let client = Client(firstName: "Ana", lastName: "Smith", phone: "3237775550199")
        XCTAssertFalse(client.matches(searchQuery: "(323) 555-0199"))
        XCTAssertFalse(client.matches(searchQuery: "p:(323) 555-0199"))
    }

    func testOnePhoneMatchCannotSatisfyUnrelatedNameTokens() {
        let client = Client(firstName: "José", lastName: "Peña", phone: "+13235550199")
        XCTAssertTrue(client.matches(searchQuery: "jose (323) 555-0199"))
        XCTAssertFalse(client.matches(searchQuery: "missing (323) 555-0199"))
        XCTAssertFalse(client.matches(searchQuery: "art alvarez 3235550199"))
        XCTAssertFalse(client.matches(searchQuery: client.uuid.uuidString))
    }

    func testSearchAcrossTenThousandOwnersHasNoCandidateLimitAndClearsToTheFullList() async throws {
        let store = try XCTUnwrap(container)
        let target = try await Task.detached {
            try await LargeSearchBook(modelContainer: store).seed(count: 10_000)
        }.value
        let repository = ClientRepository(modelContainer: store)
        for query in ["jose pena", "pena JOSE", "jose muneca golden", "(323) 555-0199", "jose 3235550199", "pet:muneca"] {
            let result = try await repository.fetchClients(query: query, limit: 20, offset: 0)
            XCTAssertEqual(result, [target], query)
        }
        for query in ["missing 3235550199", "jose poodle", "art poodle", "jose shared"] {
            let result = try await repository.fetchClientGroups(query: query)
            XCTAssertTrue(result.active.isEmpty && result.inactive.isEmpty, query)
        }
        let vm = ClientsViewModel(modelContext: context, repository: repository)
        await vm.waitForPendingFetch()
        XCTAssertEqual(vm.otherClients.count, 10_004)
        let original = vm.otherClients.map(\.uuid)
        vm.searchText = "jose muneca"
        await vm.waitForPendingFetch()
        XCTAssertEqual(vm.otherClients.map(\.persistentModelID), [target])
        vm.searchText = ""
        await vm.waitForPendingFetch()
        XCTAssertEqual(vm.otherClients.map(\.uuid), original)
        XCTAssertEqual(Set(vm.otherClients.map(\.uuid)).count, original.count)
    }

    func testBackgroundQueryCreatesItsContextAwayFromTheMainThread() async throws {
        let offMain = try await ClientBackgroundQuery.run(container: container) { context in
            _ = try context.fetchCount(FetchDescriptor<Client>())
            return !Thread.isMainThread
        }
        XCTAssertTrue(offMain)
    }

    func testBackgroundPresentationKeepsFiltersSortAndOutreachConsistent() async throws {
        let adam = Client(firstName: "Adam", lastName: "Zulu", phone: "+16265550123", email: "adam@example.com")
        let erika = Client(firstName: "Erika", lastName: "Alvarado")
        let pet = Pet(name: "Milo", species: .dog)
        context.insert(adam); context.insert(erika); context.insert(pet); pet.owner = adam
        let contact = EmergencyContact(name: "Contact", phone: "+16265550124")
        context.insert(contact); contact.owner = adam
        let visit = Visit(pet: pet)
        visit.markCheckedOut(total: 45, now: Date().addingTimeInterval(-45 * 86_400))
        context.insert(visit)
        try context.save()
        let repository = ClientRepository(modelContainer: container)
        let all = try await repository.fetchClientPresentation(query: "", filter: .all, sort: .firstName)
        XCTAssertEqual(all?.groups.inactive, [adam.persistentModelID, erika.persistentModelID])
        XCTAssertEqual(all?.needsAttention, [adam.persistentModelID])
        let overdue = try await repository.fetchClientPresentation(query: "", filter: .overdue, sort: .lastName)
        XCTAssertEqual(overdue?.groups.inactive, [adam.persistentModelID])
        let missing = try await repository.fetchClientPresentation(query: "", filter: .missingInfo, sort: .lastName)
        XCTAssertEqual(missing?.groups.inactive, [erika.persistentModelID])
        pet.recordAttentionOutreach()
        try context.save()
        let contacted = try await repository.fetchClientPresentation(query: "", filter: .overdue, sort: .lastName)
        XCTAssertTrue(contacted?.groups.inactive.isEmpty == true)
        context.insert(Visit(pet: pet))
        try context.save()
        let active = try await repository.fetchClientPresentation(query: "", filter: .active, sort: .lastName)
        XCTAssertEqual(active?.groups.active, [adam.persistentModelID])
        XCTAssertTrue(active?.groups.inactive.isEmpty == true)
    }

    func testCachedSearchRefreshesAfterDirectContextEditsVisitsAndDeletion() async throws {
        let client = Client(firstName: "José", lastName: "Peña", phone: "+13235550199")
        let pet = Pet(name: "Muñeca", species: .dog)
        context.insert(client); context.insert(pet); pet.owner = client
        try context.save()
        let repository = ClientRepository(modelContainer: container)
        let initial = try await repository.fetchClientGroups(query: "muneca")
        XCTAssertEqual(initial.inactive, [client.persistentModelID])
        pet.name = "Luna"
        context.insert(Visit(pet: pet))
        try context.save()
        let old = try await repository.fetchClientGroups(query: "muneca")
        XCTAssertTrue(old.active.isEmpty && old.inactive.isEmpty)
        let updated = try await repository.fetchClientGroups(query: "luna")
        XCTAssertEqual(updated.active, [client.persistentModelID])
        XCTAssertTrue(updated.inactive.isEmpty)
        context.delete(client)
        try context.save()
        let deleted = try await repository.fetchClientGroups(query: "luna")
        XCTAssertTrue(deleted.active.isEmpty && deleted.inactive.isEmpty)
    }
}

@ModelActor
private actor LargeSearchBook {
    /// Creates only fictional records in the test's disposable container.
    func seed(count: Int) throws -> PersistentIdentifier {
        for index in 0..<count {
            let client = Client(firstName: "Client \(index)", lastName: "Shared", phone: String(format: "+1626555%04d", index))
            let pet = Pet(name: "Luna", species: .dog)
            pet.breed = "Poodle"
            modelContext.insert(client); modelContext.insert(pet); pet.owner = client
        }
        let target = Client(firstName: "José", lastName: "Peña", phone: "+13235550199")
        let pet = Pet(name: "Muñeca", species: .dog); pet.breed = "Golden Retriever"
        modelContext.insert(target); modelContext.insert(pet); pet.owner = target
        modelContext.insert(Client(firstName: "Art", lastName: "Alvarez"))
        modelContext.insert(Client(firstName: "José", lastName: "Alvarez"))
        modelContext.insert(Client(firstName: "Art", lastName: "Peña"))
        try modelContext.save()
        return target.persistentModelID
    }
}
