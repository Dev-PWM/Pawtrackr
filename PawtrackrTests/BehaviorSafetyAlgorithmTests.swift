import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class BehaviorSafetyAlgorithmTests: XCTestCase {
    private var container: ModelContainer!
    private var petUUID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])

        let store = BehaviorSafetyTestStore(modelContainer: container)
        petUUID = try await store.seedAggressivePet()
    }

    override func tearDown() async throws {
        petUUID = nil
        container = nil
        try await super.tearDown()
    }

    func testAggressivePetKeepsSafetyFlagUntilThreeConsecutiveCalmOrCooperativeVisits() async throws {
        try await completeCheckout(with: ["Calm"])
        let firstVisitPet = try await petSnapshot()
        XCTAssertTrue(firstVisitPet.isAggressive, "One calm visit must not clear the staff safety warning.")

        try await completeCheckout(with: ["Cooperative"])
        let secondVisitPet = try await petSnapshot()
        XCTAssertTrue(secondVisitPet.isAggressive, "Two calm/cooperative visits must not clear the staff safety warning.")

        try await completeCheckout(with: ["Calm", "Cooperative"])

        let updatedPet = try await petSnapshot()
        XCTAssertFalse(updatedPet.isAggressive, "Three consecutive calm/cooperative visits should retire the aggressive warning.")
        XCTAssertEqual(Set(updatedPet.behaviorTags), Set(["Calm", "Cooperative"]))
    }

    func testAggressiveIncidentResetsCalmStreakAndRequiresThreeNewClearVisits() async throws {
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Cooperative"])
        try await completeCheckout(with: ["Aggressive"])
        let incidentPet = try await petSnapshot()
        XCTAssertTrue(incidentPet.isAggressive, "An aggressive third visit must keep the safety warning active.")

        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Cooperative"])
        let restartedStreakPet = try await petSnapshot()
        XCTAssertTrue(restartedStreakPet.isAggressive, "The streak must restart after an aggressive incident.")

        try await completeCheckout(with: ["Calm"])
        let clearedPet = try await petSnapshot()
        XCTAssertFalse(clearedPet.isAggressive, "Three new calm/cooperative visits after the reset should clear the warning.")
    }

    func testSpanishCalmAndCooperativeTagsCanClearAggressiveWarning() async throws {
        try await completeCheckout(with: ["Tranquilo"])
        try await completeCheckout(with: ["Cooperativo"])
        try await completeCheckout(with: ["Tranquilo", "Cooperativo"])

        let updatedPet = try await petSnapshot()
        XCTAssertFalse(updatedPet.isAggressive)
        XCTAssertEqual(Set(updatedPet.behaviorTags), Set(["Tranquilo", "Cooperativo"]))
    }

    func testClearanceStatusStreakProgression() async throws {
        let initialPet = try await petSnapshot()
        XCTAssertEqual(initialPet.clearanceStatus.calmStreak, 0)
        XCTAssertFalse(initialPet.clearanceStatus.isProbationary)
        XCTAssertFalse(initialPet.clearanceStatus.isCleared)
        XCTAssertEqual(initialPet.clearanceStatus.remainingVisits, 3)

        try await completeCheckout(with: ["Calm"])
        let visit1 = try await petSnapshot()
        XCTAssertEqual(visit1.clearanceStatus.calmStreak, 1)
        XCTAssertTrue(visit1.clearanceStatus.isProbationary)
        XCTAssertFalse(visit1.clearanceStatus.isCleared)
        XCTAssertEqual(visit1.clearanceStatus.remainingVisits, 2)

        try await completeCheckout(with: ["Cooperative"])
        let visit2 = try await petSnapshot()
        XCTAssertEqual(visit2.clearanceStatus.calmStreak, 2)
        XCTAssertTrue(visit2.clearanceStatus.isProbationary)
        XCTAssertFalse(visit2.clearanceStatus.isCleared)
        XCTAssertEqual(visit2.clearanceStatus.remainingVisits, 1)

        try await completeCheckout(with: ["Calm"])
        let visit3 = try await petSnapshot()
        XCTAssertEqual(visit3.clearanceStatus.calmStreak, 3)
        XCTAssertFalse(visit3.clearanceStatus.isProbationary)
        XCTAssertTrue(visit3.clearanceStatus.isCleared)
        XCTAssertEqual(visit3.clearanceStatus.remainingVisits, 0)
        XCTAssertFalse(visit3.isAggressive)
    }

    func testAggressiveRelapseAfterClearanceReturnsToAggressive() async throws {
        // Complete 3 calm visits to clear aggression
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Calm"])

        let clearedPet = try await petSnapshot()
        XCTAssertFalse(clearedPet.isAggressive, "Pet should be cleared after 3 calm visits.")
        XCTAssertTrue(clearedPet.behaviorTags.contains { Pet.isCalmOrCooperativeTag($0) }, "Cleared pet must have Calm tag.")

        // 4th visit: Pet behaves aggressively / bites
        try await completeCheckout(with: ["Aggressive"])

        let relapsedPet = try await petSnapshot()
        XCTAssertTrue(relapsedPet.isAggressive, "A single aggressive incident must immediately flag the pet as aggressive again.")
        XCTAssertEqual(relapsedPet.clearanceStatus.calmStreak, 0, "Calm streak must reset to 0 upon relapse.")
        XCTAssertFalse(relapsedPet.clearanceStatus.isProbationary)
        XCTAssertTrue(relapsedPet.behaviorTags.contains { Pet.isAggressiveTag($0) })
        XCTAssertFalse(relapsedPet.behaviorTags.contains { Pet.isCalmOrCooperativeTag($0) })
    }

    func testUntaggedVisitsDoNotAdvanceOrBreakCalmStreak() async throws {
        try await completeCheckout(with: ["Calm"])
        let visit1 = try await petSnapshot()
        XCTAssertEqual(visit1.clearanceStatus.calmStreak, 1)

        // Visit with no behavior notes logged
        try await completeCheckout(with: [])
        let untaggedVisit = try await petSnapshot()
        XCTAssertEqual(untaggedVisit.clearanceStatus.calmStreak, 1, "Untagged visits should not penalize or advance the calm streak.")
        XCTAssertTrue(untaggedVisit.isAggressive)

        // 2 more calm visits should complete the 3-visit requirement
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Calm"])

        let clearedPet = try await petSnapshot()
        XCTAssertFalse(clearedPet.isAggressive, "Two more calm visits after untagged visit should reach 3 calm visits and clear warning.")
        XCTAssertTrue(clearedPet.clearanceStatus.isCleared)
    }

    func testCheckoutViewModelTagTogglingMutualExclusivity() async throws {
        let context = container.mainContext
        var descriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.uuid == petUUID })
        descriptor.fetchLimit = 1
        let pet = try XCTUnwrap(try context.fetch(descriptor).first)
        let visit = Visit(pet: pet, user: nil)
        context.insert(visit)

        let vm = CheckoutViewModel(pet: pet, visit: visit)

        // Initial state does not pre-select Aggressive or Calm
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.aggressive.displayName))
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.calm.displayName))

        // Select Aggressive
        vm.toggleTag(Pet.BehaviorTag.aggressive.displayName)
        XCTAssertTrue(vm.tags.contains(Pet.BehaviorTag.aggressive.displayName))

        // Select Calm -> should automatically deselect Aggressive
        vm.toggleTag(Pet.BehaviorTag.calm.displayName)
        XCTAssertTrue(vm.tags.contains(Pet.BehaviorTag.calm.displayName))
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.aggressive.displayName), "Selecting Calm must deselect Aggressive.")

        // Select Aggressive again -> should automatically deselect Calm
        vm.toggleTag(Pet.BehaviorTag.aggressive.displayName)
        XCTAssertTrue(vm.tags.contains(Pet.BehaviorTag.aggressive.displayName))
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.calm.displayName), "Selecting Aggressive must deselect Calm.")
    }

    func testCheckoutViewModelHydrationDoesNotPreselectAggressiveForNewVisit() async throws {
        let context = container.mainContext
        var descriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.uuid == petUUID })
        descriptor.fetchLimit = 1
        let pet = try XCTUnwrap(try context.fetch(descriptor).first)
        pet.setBehaviorTags(["Aggressive", "Special Needs"])
        try context.save()

        let visit = Visit(pet: pet, user: nil)
        context.insert(visit)

        let vm = CheckoutViewModel(pet: pet, visit: visit)

        XCTAssertTrue(vm.tags.contains("Special Needs"), "Standing care tags must be preserved.")
        XCTAssertFalse(vm.tags.contains("Aggressive"), "Aggressive tag must not be pre-selected on a new checkout visit session.")
        XCTAssertFalse(vm.tags.contains("Calm"))
    }

    func testMixedNonAggressiveObservationsClearAndUseOnlyLatestMood() async throws {
        try await completeCheckout(with: ["Anxious"])
        let first = try await petSnapshot()
        XCTAssertTrue(first.isAggressive)
        XCTAssertEqual(first.clearanceStatus.calmStreak, 1)
        XCTAssertTrue(first.behaviorTags.contains("Anxious"))
        try await completeCheckout(with: ["Cooperative"])
        let second = try await petSnapshot()
        XCTAssertTrue(second.isAggressive)
        XCTAssertTrue(second.behaviorTags.contains("Cooperative"))
        try await completeCheckout(with: ["Nervous"])
        let third = try await petSnapshot()
        XCTAssertFalse(third.isAggressive)
        XCTAssertEqual(third.behaviorTags, ["Nervous"], "Old calm/green tags must not override today's blue observation.")
        XCTAssertEqual(third.prominentBehavior, .nervous)
    }

    func testHistoricalAggressiveObservationSurvivesClearanceAndLaterMoodChanges() async throws {
        try await completeCheckout(with: ["Aggressive"])
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Nervous"])
        try await completeCheckout(with: ["Cooperative"])
        let cleared = try await petSnapshot()
        XCTAssertFalse(cleared.isAggressive)
        try await completeCheckout(with: ["Anxious"])
        let latest = try await petSnapshot()
        XCTAssertEqual(latest.behaviorTags, ["Anxious"])
        let reader = BehaviorSafetyTestStore(modelContainer: container)
        let observations = try await reader.historicalObservations(for: petUUID)
        XCTAssertEqual(observations, [["Aggressive"], ["Calm"], ["Nervous"], ["Cooperative"], ["Anxious"]])
    }

    func testSpanishAnxiousAndNervousQualifyForClearance() async throws {
        try await completeCheckout(with: ["Ansioso"])
        try await completeCheckout(with: ["Nervioso"])
        try await completeCheckout(with: ["Tranquilo"])
        let snapshot = try await petSnapshot()
        XCTAssertFalse(snapshot.isAggressive)
        XCTAssertEqual(snapshot.prominentBehavior, .calm)
    }

    func testSpecialNeedsSurvivesClearanceAndAggressiveRelapse() async throws {
        try await completeCheckout(with: ["Aggressive", "Special Needs"])
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Anxious"])
        try await completeCheckout(with: ["Nervous"])
        let cleared = try await petSnapshot()
        XCTAssertFalse(cleared.isAggressive)
        XCTAssertTrue(cleared.behaviorTags.contains("Special Needs"))
        XCTAssertEqual(cleared.prominentBehavior, .specialNeeds)
        try await completeCheckout(with: ["Aggressive"])
        let relapse = try await petSnapshot()
        XCTAssertTrue(relapse.isAggressive)
        XCTAssertTrue(relapse.behaviorTags.contains("Special Needs"))
        XCTAssertEqual(relapse.prominentBehavior, .aggressive)
        XCTAssertEqual(relapse.clearanceStatus.calmStreak, 0)
    }

    func testCareOnlyVisitsAreNotTemperamentEvidence() async throws {
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Special Needs"])
        let careOnly = try await petSnapshot()
        XCTAssertTrue(careOnly.isAggressive)
        XCTAssertTrue(careOnly.behaviorTags.contains("Calm"))
        XCTAssertEqual(careOnly.clearanceStatus.calmStreak, 1)
        try await completeCheckout(with: ["Anxious"])
        try await completeCheckout(with: ["Nervous"])
        let cleared = try await petSnapshot()
        XCTAssertFalse(cleared.isAggressive)
        XCTAssertTrue(cleared.behaviorTags.contains("Special Needs"))
    }

    func testAggressionOverridesContradictoryImportedObservation() async throws {
        try await completeCheckout(with: ["Calm"])
        try await completeCheckout(with: ["Aggressive", "Nervous"])
        let snapshot = try await petSnapshot()
        XCTAssertTrue(snapshot.isAggressive)
        XCTAssertEqual(snapshot.clearanceStatus.calmStreak, 0)
        XCTAssertEqual(snapshot.prominentBehavior, .aggressive)
    }

    func testCheckoutAnxiousAndNervousSelectionExcludeAggressionButKeepCare() async throws {
        let pet = Pet(name: "Handling", species: .dog)
        let visit = Visit(pet: pet, user: nil)
        let vm = CheckoutViewModel(pet: pet, visit: visit)
        vm.toggleTag(Pet.BehaviorTag.specialNeeds.displayName)
        vm.toggleTag(Pet.BehaviorTag.aggressive.displayName)
        vm.toggleTag(Pet.BehaviorTag.anxious.displayName)
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.aggressive.displayName))
        vm.toggleTag(Pet.BehaviorTag.aggressive.displayName)
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.anxious.displayName))
        vm.toggleTag(Pet.BehaviorTag.nervous.displayName)
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.aggressive.displayName))
        XCTAssertTrue(vm.tags.contains(Pet.BehaviorTag.specialNeeds.displayName))
        vm.toggleTag(Pet.BehaviorTag.calm.displayName)
        XCTAssertFalse(vm.tags.contains(Pet.BehaviorTag.nervous.displayName))
        XCTAssertTrue(vm.tags.contains(Pet.BehaviorTag.calm.displayName))
    }

    func testNewVisitDoesNotPreselectPreviousAnxietyAsClearanceEvidence() {
        let pet = Pet(name: "Fresh observation", species: .dog)
        pet.setBehaviorTags(["Aggressive", "Anxious", "Nervous", "Special Needs", "Friendly", "Needs breaks"])
        let visit = Visit(pet: pet, user: nil)
        let vm = CheckoutViewModel(pet: pet, visit: visit)
        XCTAssertEqual(vm.tags, Set(["Special Needs"]))
    }

    private func completeCheckout(with behaviorTags: [String]) async throws {
        let actor = CheckoutTransactionActor(modelContainer: container)
        let request = CheckoutRequest(
            visitUUID: UUID(),
            petUUID: petUUID,
            clientUUID: nil,
            amount: Decimal(40),
            paymentMethod: .cash,
            externalReference: nil,
            sessionNotes: nil,
            behaviorTags: behaviorTags,
            beforePhotoData: nil,
            afterPhotoData: nil,
            selectedServiceIDs: [],
            selectedAddOnIDs: []
        )

        _ = try await actor.process(request)
        try await Task.sleep(for: .milliseconds(5))
    }

    private func petSnapshot() async throws -> BehaviorSafetyPetSnapshot {
        let store = BehaviorSafetyTestStore(modelContainer: container)
        return try await store.snapshot(for: petUUID)
    }
}

private struct BehaviorSafetyPetSnapshot: Sendable {
    let behaviorTags: [String]
    let isAggressive: Bool
    let clearanceStatus: Pet.AggressionClearanceStatus
    let prominentBehavior: Pet.BehaviorTag?
}

@ModelActor
private actor BehaviorSafetyTestStore {
    func seedAggressivePet() throws -> UUID {
        let pet = Pet(name: "Safety Buddy", species: .dog)
        pet.setBehaviorTags(["Aggressive"])
        modelContext.insert(pet)
        try modelContext.save()
        return pet.uuid
    }

    func historicalObservations(for petUUID: UUID) throws -> [[String]] {
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.pet?.uuid == petUUID && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.endedAt)]
        )
        return try modelContext.fetch(descriptor).map(\.behaviorTags)
    }

    func snapshot(for petUUID: UUID) throws -> BehaviorSafetyPetSnapshot {
        var descriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.uuid == petUUID })
        descriptor.fetchLimit = 1
        let pet = try XCTUnwrap(try modelContext.fetch(descriptor).first)
        return BehaviorSafetyPetSnapshot(
            behaviorTags: pet.behaviorTags,
            isAggressive: pet.isAggressive,
            clearanceStatus: pet.aggressionClearanceStatus,
            prominentBehavior: pet.prominentBehavior
        )
    }
}
