import XCTest
import SwiftData
@testable import Pawtrackr

/// Coverage for ClientDetailViewModel — paging, range filtering, observer-driven refresh,
/// and the check-in/check-out/add-service actions powering the per-client detail screen.
@MainActor
final class ClientDetailViewModelTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var client: Client!
    var pet: Pet!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext

        client = Client(firstName: "Jane", lastName: "Doe", phone: "5551234567")
        context.insert(client)
        pet = Pet(name: "Buddy", species: .dog)
        pet.owner = client
        context.insert(pet)
        try context.save()

        Formatters.updateCurrencySymbol("$")
    }

    override func tearDownWithError() throws {
        container = nil; context = nil; client = nil; pet = nil
    }

    func testInit_PopulatesPetsFromClient() async {
        let vm = ClientDetailViewModel(client: client, modelContext: context)
        XCTAssertEqual(vm.pets.count, 1)
        XCTAssertEqual(vm.pets.first?.uuid, pet.uuid)
    }

    func testRefreshPetsReadsCommittedBehaviorAndNewPetWithoutDirtyingOldGraph() throws {
        let vm = ClientDetailViewModel(client: client, modelContext: context)
        _ = vm.pets.first?.behaviorTags
        let originalRevision = vm.petPresentationRevision
        let writer = ModelContext(container)
        let storedPet = try XCTUnwrap(writer.model(for: pet.persistentModelID) as? Pet)
        storedPet.behaviorTags = ["Nervous"]
        let added = Pet(name: "Luna", species: .dog)
        added.owner = storedPet.owner
        writer.insert(added)
        try writer.save()

        vm.refreshPets()

        XCTAssertGreaterThan(vm.petPresentationRevision, originalRevision, "Same model IDs still need a new display revision after graph replacement.")
        XCTAssertEqual(vm.pets.count, 2)
        XCTAssertEqual(vm.pets.first(where: { $0.uuid == pet.uuid })?.behaviorTags, ["Nervous"])
        XCTAssertFalse(context.hasChanges, "Refreshing committed data must not dirty the original graph.")
        XCTAssertFalse(vm.client.modelContext?.hasChanges ?? true)
    }

    func testRefreshPetsPreservesUnsavedClientEdits() throws {
        let vm = ClientDetailViewModel(client: client, modelContext: context)
        let originalRevision = vm.petPresentationRevision
        client.firstName = "Unsaved"
        vm.refreshPets()
        XCTAssertTrue(vm.client === client)
        XCTAssertEqual(vm.petPresentationRevision, originalRevision, "Unsaved editor graphs must not be replaced or remounted.")
        XCTAssertEqual(vm.client.firstName, "Unsaved")
        XCTAssertTrue(context.hasChanges)
    }

    func testContactEditorSurvivesPresentationRefreshAndPreservesUntouchedFields() throws {
        let contact = EmergencyContact(name: "Riley", relation: "friend", phone: "+13125550112")
        contact.owner = client
        context.insert(contact)
        try context.save()
        let vm = ClientDetailViewModel(client: client, modelContext: context)
        let writer = ModelContext(container)
        let stored = try XCTUnwrap(writer.model(for: contact.persistentModelID) as? EmergencyContact)
        stored.relation = "sibling"
        try writer.save()
        vm.refreshPets()

        let result = vm.saveEmergencyContact(editing: contact, name: "Riley Updated", relation: "friend", phone: contact.phone)
        XCTAssertEqual(result, .saved)
        let reader = ModelContext(container)
        let saved = try XCTUnwrap(reader.model(for: contact.persistentModelID) as? EmergencyContact)
        XCTAssertEqual(saved.name, "Riley Updated")
        XCTAssertEqual(saved.relation, "sibling")
        XCTAssertFalse(context.hasChanges)
    }

    func testInit_PopulatesEmergencyContactsFromClientRelationship() async throws {
        let contact = EmergencyContact(name: "Riley Backup", relation: "friend", phone: "+13125550111")
        contact.owner = client
        context.insert(contact)
        client.emergencyContacts = [contact]
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)

        XCTAssertEqual(vm.emergencyContacts.map(\.name), ["Riley Backup"])
    }

    func testRefreshEmergencyContactsFetchesContactsByOwnerRelationship() async throws {
        let backgroundContext = ModelContext(container)
        let backgroundClient = try XCTUnwrap(backgroundContext.model(for: client.persistentModelID) as? Client)
        let contact = EmergencyContact(name: "Jordan Backup", relation: "sibling", phone: "+13125550112")
        contact.owner = backgroundClient
        backgroundContext.insert(contact)
        try backgroundContext.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        vm.refreshEmergencyContacts()

        XCTAssertEqual(vm.emergencyContacts.map(\.name), ["Jordan Backup"])
    }

    func testRefreshRecentVisits_ReturnsCompletedVisitsForClient() async throws {
        seedCompletedVisit(at: .now, total: 30)
        seedCompletedVisit(at: .now, total: 45)

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        await waitForFetch(vm)

        XCTAssertEqual(vm.recentVisits.count, 2)
        XCTAssertEqual(vm.visitCount, 2)
        XCTAssertEqual(vm.grandRevenue, Decimal(string: "75.00"))
    }

    func testRefreshRecentVisits_ExcludesUnfinishedVisits() async throws {
        // Active (no endedAt) — must not appear in recentVisits.
        let active = Visit(pet: pet)
        context.insert(active)
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        await waitForFetch(vm)

        XCTAssertEqual(vm.recentVisits.count, 0,
            "recentVisits should only contain completed visits (endedAt != nil).")
    }

    func testHistoryRange_LastNDays_FiltersOutOlderVisits() async throws {
        let cal = Calendar.current
        let oldDate = try XCTUnwrap(cal.date(byAdding: .day, value: -90, to: .now))
        seedCompletedVisit(at: oldDate, total: 99)
        seedCompletedVisit(at: .now, total: 30)

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        await waitForFetch(vm)
        XCTAssertEqual(vm.recentVisits.count, 2, "Default `.all` range returns both.")

        vm.historyRange = .lastNDays(30)
        await waitForFetch(vm)

        XCTAssertEqual(vm.recentVisits.count, 1,
            "lastNDays(30) must filter out the 90-days-old visit.")
        XCTAssertEqual(vm.grandRevenue, Decimal(string: "30.00"))
    }

    func testLoadMore_BumpsPaginationLimit() async throws {
        for _ in 0..<8 {
            seedCompletedVisit(at: .now, total: 10)
        }

        // initialLimit=5 → first page returns 5, canLoadMore true, loadMore → 8 (all).
        let vm = ClientDetailViewModel(client: client, modelContext: context, initialLimit: 5)
        await waitForFetch(vm)
        XCTAssertEqual(vm.recentVisits.count, 5)
        XCTAssertTrue(vm.canLoadMore)

        vm.loadMore()
        await waitForFetch(vm)
        XCTAssertEqual(vm.recentVisits.count, 8)
        XCTAssertFalse(vm.canLoadMore)
    }

    func testActiveVisit_ReturnsOpenVisitForPet() async throws {
        let active = Visit(pet: pet)
        context.insert(active)
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        let found = vm.activeVisit(for: pet)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.uuid, active.uuid)
    }

    func testActiveVisit_ClearedAfterCrossContextCheckout() async throws {
        // Seed an open visit on the main context — pet starts "In Session".
        let active = Visit(pet: pet)
        context.insert(active)
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        XCTAssertNotNil(vm.activeVisit(for: pet), "An open visit must register as active.")

        // Reproduce the bug's trigger: end the visit on a SEPARATE context of the
        // same container, exactly as CheckoutTransactionActor (@ModelActor) does.
        // The main context's materialized `pet.visits` relationship can stay stale
        // here — which is what left the "In Session" badge stuck.
        let bgContext = ModelContext(container)
        let bgVisit = try XCTUnwrap(bgContext.model(for: active.persistentModelID) as? Visit)
        bgVisit.markCheckedOut(total: 50, now: .now)
        try bgContext.save()

        // The completion broadcast posted after checkout.
        NotificationCenter.default.post(
            name: .visitDidComplete,
            object: nil,
            userInfo: [VisitDidCompleteKey.clientID.rawValue: client.persistentModelID]
        )
        try await Task.sleep(for: .milliseconds(150)) // let the main-actor observer refresh

        XCTAssertNil(vm.activeVisit(for: pet),
            "After checkout commits on the actor's context, the pet must no longer report an active visit — the store-level query excludes the now-ended visit even if the relationship is stale.")
    }

    func testActiveVisit_RevalidatesStaleIDAfterCrossContextCheckoutWithoutNotification() async throws {
        let active = Visit(pet: pet)
        context.insert(active)
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        XCTAssertNotNil(vm.activeVisit(for: pet))

        let bgContext = ModelContext(container)
        let bgVisit = try XCTUnwrap(bgContext.model(for: active.persistentModelID) as? Visit)
        bgVisit.markCheckedOut(total: 50, now: .now)
        try bgContext.save()

        XCTAssertNil(
            vm.activeVisit(for: pet),
            "Active-session UI must re-check the store when asked, so switching tabs cannot revive a visit that checkout ended in another context."
        )
    }

    func testCheckIn_NoOpWhenActiveVisitAlreadyExists() async throws {
        let active = Visit(pet: pet, startedAt: .now)
        context.insert(active)
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        vm.checkIn(pet: pet, at: .now)
        // Wait for any internal Task to settle
        try await Task.sleep(for: .milliseconds(100))

        let activeVisits = (pet.visits ?? []).filter { $0.endedAt == nil }
        XCTAssertEqual(activeVisits.count, 1,
            "Calling checkIn while a visit is already active must not create a second one.")
    }

    func testCheckIn_LocksPetImmediatelyWhileSaveRuns() async throws {
        let vm = ClientDetailViewModel(client: client, modelContext: context)

        XCTAssertFalse(vm.isCheckingIn(pet))
        vm.checkIn(pet: pet, at: .now)

        XCTAssertTrue(
            vm.isCheckingIn(pet) || vm.activeVisit(for: pet) != nil,
            "Check-in should immediately make the pet unavailable for another check-in tap."
        )
    }

    func testVisitDidCompleteNotification_TriggersRefresh() async throws {
        let vm = ClientDetailViewModel(client: client, modelContext: context)
        await waitForFetch(vm)
        XCTAssertEqual(vm.recentVisits.count, 0)

        seedCompletedVisit(at: .now, total: 25)
        // Simulate a checkout completion posted by VisitRepository / CheckoutTransactionActor.
        NotificationCenter.default.post(
            name: .visitDidComplete,
            object: nil,
            userInfo: [VisitDidCompleteKey.clientID.rawValue: client.persistentModelID]
        )

        await waitForFetch(vm, expectVisits: 1)
        XCTAssertEqual(vm.recentVisits.count, 1,
            "ClientDetailVM must refresh when .visitDidComplete fires for this client.")
    }

    func testVisitDidCompleteNotification_OtherClient_DoesNotTriggerRefresh() async throws {
        let otherClient = Client(firstName: "Other", lastName: "Owner", phone: "5559998888")
        context.insert(otherClient)
        try context.save()

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        await waitForFetch(vm)

        // Post a completion notification for a DIFFERENT client's visit.
        seedCompletedVisit(at: .now, total: 25)
        NotificationCenter.default.post(
            name: .visitDidComplete,
            object: nil,
            userInfo: [VisitDidCompleteKey.clientID.rawValue: otherClient.persistentModelID]
        )
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(vm.recentVisits.count, 0,
            "VM must ignore .visitDidComplete events for other clients.")
    }

    func testRecordAttentionOutreach_ClearsNeedsAttentionForDuePet() async throws {
        pet.preferredGroomingFrequency = .weekly
        let twoWeeksAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -14, to: .now))
        seedCompletedVisit(at: twoWeeksAgo, total: 30)

        XCTAssertTrue(pet.needsAttention)

        let vm = ClientDetailViewModel(client: client, modelContext: context)
        vm.recordAttentionOutreach(method: "call")

        XCTAssertNotNil(pet.lastAttentionOutreachAt)
        XCTAssertFalse(pet.needsAttention)
    }

    // MARK: - Helpers

    /// `refreshRecentVisits` is non-async; poll `recentVisits.count` (or a custom predicate)
    /// to wait for the internal Task to finish populating data.
    private func waitForFetch(
        _ vm: ClientDetailViewModel,
        expectVisits: Int? = nil,
        timeout: TimeInterval = 2.0
    ) async {
        let start = Date()
        try? await Task.sleep(for: .milliseconds(50))
        while Date().timeIntervalSince(start) < timeout {
            if let target = expectVisits {
                if vm.recentVisits.count >= target { break }
            } else {
                // No explicit target — wait a short settle window.
                try? await Task.sleep(for: .milliseconds(100))
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @discardableResult
    private func seedCompletedVisit(at endedAt: Date, total: Decimal) -> Visit {
        let visit = Visit(pet: pet, startedAt: endedAt.addingTimeInterval(-1800))
        context.insert(visit)
        visit.addItem(title: "Bath", unitPrice: total)
        let payment = Payment(amount: total, method: .cash, paidAt: endedAt)
        context.insert(payment)
        visit.attachPayment(payment)
        visit.markCheckedOut(total: total, now: endedAt)
        try? context.save()
        return visit
    }
}
