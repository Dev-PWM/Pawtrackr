import XCTest
@testable import Pawtrackr

@MainActor
final class ClientCardVisualStateTests: XCTestCase {
    func testSpecialNeedsRemainsPriorityAfterAggressionIsCleared() {
        let client = Client(firstName: "Priority", lastName: "Care")
        let pet = Pet(name: "Care Buddy", species: .dog)
        client.addPet(pet)
        pet.setBehaviorTags(["Aggressive", "Special Needs"])
        let both = ClientCard.VisualState(client: client, isInProgressOverride: false)
        XCTAssertTrue(both.showsAggressiveWarning)
        XCTAssertTrue(both.showsSpecialNeedsWarning)
        XCTAssertEqual(both.accentKind, .safety)
        pet.setBehaviorTags(["Calm", "Special Needs"])
        let care = ClientCard.VisualState(client: client, isInProgressOverride: true)
        XCTAssertFalse(care.showsAggressiveWarning)
        XCTAssertTrue(care.showsSpecialNeedsWarning)
        XCTAssertEqual(care.accentKind, .priorityCare)
    }
    func testClearingAggressiveBehaviorDropsSafetyAccentAndChangesCardIdentity() {
        let client = Client(firstName: "Hello", lastName: "World", phone: "3157818455")
        let pet = Pet(name: "Why", species: .dog)
        pet.setBehaviorTags(["Aggressive"])
        client.addPet(pet)

        let aggressiveState = ClientCard.VisualState(client: client, isInProgressOverride: false)
        XCTAssertTrue(aggressiveState.showsAggressiveWarning)
        XCTAssertEqual(aggressiveState.accentKind, .safety)

        pet.setBehaviorTags(["Calm", "Cooperative"])

        let clearedState = ClientCard.VisualState(client: client, isInProgressOverride: false)
        XCTAssertFalse(clearedState.showsAggressiveWarning)
        XCTAssertNil(clearedState.accentKind)
        XCTAssertNotEqual(
            aggressiveState.identityKey,
            clearedState.identityKey,
            "The card identity must change when the safety rail is removed so iOS/iPad LazyVStack reuse cannot leave the old red overlay behind."
        )
    }

    func testInProgressAccentDoesNotBecomeSafetyAccentWhenPetIsNotAggressive() {
        let client = Client(firstName: "Luis", lastName: "Pacheco")
        let pet = Pet(name: "Loui", species: .dog)
        pet.setBehaviorTags(["Cooperative"])
        client.addPet(pet)

        let state = ClientCard.VisualState(client: client, isInProgressOverride: true)

        XCTAssertFalse(state.showsAggressiveWarning)
        XCTAssertEqual(state.accentKind, .inProgress)
    }
}
