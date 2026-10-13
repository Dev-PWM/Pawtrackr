import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class RandomWorkflowFuzzTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var dataStore: DataStoreService!
    private var eventBus: GlobalEventBus!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        dataStore = DataStoreService(container: container)
        eventBus = GlobalEventBus()
        Formatters.updateCurrencySymbol("$")
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        dataStore = nil
        eventBus = nil
    }

    func testRandomizedClientPetVisitCheckoutDashboardWorkflow() async throws {
        let services = try seedPricedServices()
        let mainServices = services.filter { $0.category != .addOn }
        let addOns = services.filter { $0.category == .addOn }
        XCTAssertFalse(mainServices.isEmpty)
        XCTAssertFalse(addOns.isEmpty)

        var rng = SeededRandom(state: 0xC0FFEE)
        var created: [(first: String, last: String, pet: String)] = []

        for index in 0..<30 {
            let names = randomClient(index: index, rng: &rng)
            let vm = NewClientViewModel(modelContext: context)
            vm.first = names.first
            vm.last = names.last
            vm.phone = validPhone(index)
            vm.email = "\(names.first).\(names.last).\(index)@example.com".lowercased()
            vm.address = "\(100 + index) Market St"

            vm.pets[0].name = names.pet
            vm.pets[0].species = rng.nextBool() ? .dog : .cat
            vm.pets[0].gender = rng.nextBool() ? .male : .female
            vm.pets[0].breed = randomBreed(rng: &rng)
            vm.pets[0].color = randomColor(rng: &rng)
            vm.pets[0].health = "No known issues \(index)"
            vm.pets[0].behaviorTags = Set([Pet.BehaviorTag.allCases[rng.nextInt(Pet.BehaviorTag.allCases.count)].displayName])

            if rng.nextInt(3) == 0 {
                vm.addPet()
                vm.pets[1].name = "\(randomPetName(rng: &rng)) \(index)"
                vm.pets[1].species = rng.nextBool() ? .dog : .cat
                vm.pets[1].gender = rng.nextBool() ? .male : .female
            }

            vm.contacts[0].name = "Backup \(index)"
            vm.contacts[0].relation = "family"
            vm.contacts[0].phone = validPhone(500 + index)

            let outcome = await vm.createClient()
            XCTAssertEqual(outcome, .created)
            XCTAssertNil(vm.appError)
            created.append((names.first, names.last, names.pet))
        }

        let clients = try context.fetch(FetchDescriptor<Client>())
        let pets = try context.fetch(FetchDescriptor<Pet>())
        XCTAssertEqual(clients.count, 30)
        XCTAssertGreaterThanOrEqual(pets.count, 30)
        XCTAssertTrue(clients.allSatisfy { !($0.pets ?? []).isEmpty })

        let clientRepository = ClientRepository(modelContainer: container)
        let firstCreated = try XCTUnwrap(created.first)
        let nameMatches = try await clientRepository.fetchClients(query: "n:\(firstCreated.last)", limit: 10, offset: 0)
        let nameMatchClients = nameMatches.compactMap { context.model(for: $0) as? Client }
        XCTAssertTrue(nameMatchClients.contains { $0.lastName == firstCreated.last })

        let petMatches = try await clientRepository.fetchClients(query: "pet:\(firstCreated.pet)", limit: 10, offset: 0)
        let petMatchClients = petMatches.compactMap { context.model(for: $0) as? Client }
        XCTAssertTrue(petMatchClients.contains { ($0.pets ?? []).contains { $0.name == firstCreated.pet } })

        let checkoutPets = Array(pets.prefix(8))
        let visitRepository = VisitRepository(modelContext: container.mainContext, eventBus: eventBus)
        let paymentMethods: [Payment.Method] = [.cash, .creditCard, .debitCard, .zelle, .other]
        var expectedRevenue = Decimal.zero

        for (index, pet) in checkoutPets.enumerated() {
            let startedAt = Date().addingTimeInterval(TimeInterval(-(index + 1) * 1800))
            let visit = try await visitRepository.checkIn(pet: pet, date: startedAt)
            let checkout = makeCheckoutViewModel(pet: pet, visit: visit)
            checkout.allServices = mainServices
            checkout.addOnServices = addOns

            checkout.toggleService(mainServices[index % mainServices.count])
            checkout.toggleAddOn(addOns[index % addOns.count])
            checkout.setAmountDirectly(String(45 + index * 7))
            checkout.setSessionNotes("Randomized checkout note \(index)")
            checkout.toggleTag(Pet.BehaviorTag.allCases[index % Pet.BehaviorTag.allCases.count].displayName)

            let method = paymentMethods[index % paymentMethods.count]
            checkout.choosePayment(method)
            if method.requiresExternalReference {
                checkout.setExternalReference("REF-\(1000 + index)")
            }

            try checkout.advance()
            try checkout.advance()
            try checkout.advance()

            let total = checkout.servicesTotalDecimal
            XCTAssertGreaterThan(total, Decimal.zero)
            await checkout.processPayment()

            XCTAssertEqual(checkout.state, CheckoutViewModel.CheckoutState.confirmed)
            XCTAssertNil(checkout.appError)
            
            XCTAssertNotNil(checkout.visit.endedAt)
            XCTAssertEqual(checkout.visit.total, total)
            XCTAssertEqual(checkout.visit.payment?.amount, total)
            expectedRevenue += total
        }

        SummaryUpdater.rebuildDay(for: Date(), in: context)

        let dashboard = DashboardRepository(modelContext: container.mainContext)
        let kpis = try await dashboard.fetchKPIs()
        XCTAssertEqual(kpis.inProgressCount, 0)
        XCTAssertEqual(kpis.completedToday, checkoutPets.count)
        XCTAssertEqual(kpis.revenueToday, expectedRevenue.roundedMoney())

        let serviceDistribution = try await dashboard.fetchServiceDistribution(days: 1)
        let categoryDistribution = try await dashboard.fetchCategoryDistribution(days: 1)
        XCTAssertFalse(serviceDistribution.isEmpty)
        XCTAssertFalse(categoryDistribution.isEmpty)

        let insights = InsightsViewModel(dataStore: dataStore)
        await insights.refresh()
        XCTAssertEqual(insights.totalRevenue, expectedRevenue.roundedMoney())
        XCTAssertEqual(insights.totalVisitsInPeriod, checkoutPets.count)

        let activeClients = try await clientRepository.fetchActiveClients(query: "")
        XCTAssertTrue(activeClients.isEmpty)
    }

    func testCheckoutViewModel_ResilienceFuzz() async throws {
        let pet = Pet(name: "FuzzPet", species: .dog)
        context.insert(pet)
        let visit = Visit(pet: pet)
        context.insert(visit)
        
        let vm = makeCheckoutViewModel(pet: pet, visit: visit)
        vm.allServices = try seedPricedServices()
        
        var rng = SeededRandom(state: 0xDEADBEEF)
        
        // Fuzz interactions for 500 iterations
        for _ in 0..<500 {
            let action = rng.nextInt(6)
            switch action {
            case 0: vm.toggleService(vm.allServices.randomElement()!)
            case 1: vm.toggleAddOn(vm.allServices.randomElement()!)
            case 2: vm.setSessionNotes("Random \(rng.next())")
            case 3: vm.setAmountDirectly("\(rng.nextInt(100)).\(rng.nextInt(99))")
            case 4: vm.choosePayment(Payment.Method.allCases.randomElement()!)
            case 5: _ = try? vm.advance()
            default: break
            }
        }
        
        // Assert we ended in a sane state
        XCTAssertNotNil(vm.state)
    }

    private func seedPricedServices() throws -> [Service] {
        DataMigrations.ensureServiceCatalog(in: context)
        let services = try context.fetch(FetchDescriptor<Service>(sortBy: [SortDescriptor(\.name)]))
        for (index, service) in services.enumerated() {
            service.setBasePrice(Decimal(25 + index * 3))
        }
        try context.save()
        return services
    }

    private func makeCheckoutViewModel(pet: Pet, visit: Visit) -> CheckoutViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return CheckoutViewModel(
            pet: pet,
            visit: visit,
            draftStore: CheckoutDraftStore(directoryURL: root),
            eventRecorder: CheckoutEventRecorder(logURL: root.appendingPathComponent("checkout.log"))
        )
    }

    private func randomClient(index: Int, rng: inout SeededRandom) -> (first: String, last: String, pet: String) {
        (
            "\(Self.firstNames[rng.nextInt(Self.firstNames.count)])\(index)",
            Self.lastNames[rng.nextInt(Self.lastNames.count)],
            "\(randomPetName(rng: &rng))\(index)"
        )
    }

    private func randomPetName(rng: inout SeededRandom) -> String {
        Self.petNames[rng.nextInt(Self.petNames.count)]
    }

    private func randomBreed(rng: inout SeededRandom) -> String {
        Self.breeds[rng.nextInt(Self.breeds.count)]
    }

    private func randomColor(rng: inout SeededRandom) -> String {
        Self.colors[rng.nextInt(Self.colors.count)]
    }

    private func validPhone(_ index: Int) -> String {
        String(format: "312555%04d", 1000 + index)
    }

    private static let firstNames = ["Ava", "Mia", "Noah", "Liam", "Sofia", "Emma", "Leo", "Eli"]
    private static let lastNames = ["Rivera", "Chen", "Patel", "Garcia", "Brown", "Wilson", "Kim", "Lopez"]
    private static let petNames = ["Luna", "Milo", "Coco", "Max", "Nala", "Rocky", "Bella", "Teddy"]
    private static let breeds = ["Poodle", "Terrier", "Retriever", "Tabby", "Maltese", "Bulldog"]
    private static let colors = ["black", "white", "gold", "brown", "gray", "cream"]
}

private struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        nextInt(2) == 0
    }
}
