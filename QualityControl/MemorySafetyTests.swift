import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class MemorySafetyTests: XCTestCase {
    func testOneHundredClientDetailAndCheckoutModelLifecyclesRelease() async throws {
        let dataStore = DataStoreService(inMemory: true)
        let context = dataStore.container.mainContext
        let client = Client(firstName: "Memory", lastName: "Test")
        let pet = Pet(name: "Fictional pet", species: .dog)
        context.insert(client); context.insert(pet); pet.owner = client
        let visit = Visit(pet: pet)
        context.insert(visit)
        try context.save()
        let bus = GlobalEventBus()
        for cycle in 0..<100 {
            var detail: ClientDetailViewModel? = ClientDetailViewModel(client: client, modelContext: context, eventBus: bus)
            var checkout: CheckoutViewModel? = CheckoutViewModel(pet: pet, visit: visit,
                draftStore: CheckoutDraftStore(inMemory: true),
                eventRecorder: CheckoutEventRecorder(persistsEvents: false), eventBus: bus)
            weak var releasedDetail = detail
            weak var releasedCheckout = checkout
            detail = nil; checkout = nil
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while releasedDetail != nil || releasedCheckout != nil {
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(releasedDetail, "Client detail retained in cycle \(cycle)")
            XCTAssertNil(releasedCheckout, "Checkout retained in cycle \(cycle)")
        }
    }

    func testDashboardAndRecentHistoryReleaseAfterRefreshing() async throws {
        let dataStore = DataStoreService(inMemory: true)
        let bus = GlobalEventBus()
        var dashboard: DashboardViewModel? = DashboardViewModel(dataStore: dataStore, eventBus: bus)
        var history: RecentHistoryViewModel? = RecentHistoryViewModel(dataStore: dataStore, eventBus: bus)
        weak var releasedDashboard = dashboard
        weak var releasedHistory = history
        await dashboard?.refresh()
        dashboard = nil; history = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while releasedDashboard != nil || releasedHistory != nil {
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(releasedDashboard)
        XCTAssertNil(releasedHistory)
    }

    func testObservationOwnerCancelsStreamOnRelease() async {
        let terminated = expectation(description: "Stream subscription removed")
        let stream = AsyncStream<Void> { continuation in
            continuation.onTermination = { _ in terminated.fulfill() }
        }
        var owner: EventObservationLifetime? = EventObservationLifetime()
        owner?.task = Task { for await _ in stream {} }
        await Task.yield()
        owner = nil
        await fulfillment(of: [terminated], timeout: 1)
    }
}
