import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class PetMilestoneTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func date(_ year: Int, _ month: Int = 10, _ day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testAgeBoundariesAndSpeciesDiffer() {
        let now = date(2026)
        XCTAssertEqual(PetLifeStage.estimate(birthdate: date(2025, 10, 13), species: .dog, on: now, calendar: calendar), .young)
        XCTAssertEqual(PetLifeStage.estimate(birthdate: date(2025), species: .dog, on: now, calendar: calendar), .adult)
        XCTAssertEqual(PetLifeStage.estimate(birthdate: date(2018), species: .dog, on: now, calendar: calendar), .senior)
        XCTAssertEqual(PetLifeStage.estimate(birthdate: date(2018), species: .cat, on: now, calendar: calendar), .adult)
        XCTAssertEqual(PetLifeStage.estimate(birthdate: date(2015), species: .cat, on: now, calendar: calendar), .senior)
        XCTAssertNil(PetLifeStage.estimate(birthdate: nil, species: .dog, on: now, calendar: calendar))
        XCTAssertNil(PetLifeStage.estimate(birthdate: date(2027), species: .dog, on: now, calendar: calendar))
    }

    func testAnniversaryIgnoresYearAndHandlesLeapDayAndFutureDates() {
        XCTAssertTrue(PetMilestones.isAnniversary(date(2010), on: date(2026), calendar: calendar))
        XCTAssertFalse(PetMilestones.isAnniversary(date(2010), on: date(2026, 10, 13), calendar: calendar))
        XCTAssertFalse(PetMilestones.isAnniversary(date(2027), on: date(2026), calendar: calendar))
        XCTAssertTrue(PetMilestones.isAnniversary(date(2024, 2, 29), on: date(2025, 2, 28), calendar: calendar))
        XCTAssertFalse(PetMilestones.isAnniversary(date(2024, 2, 29), on: date(2028, 2, 28), calendar: calendar))
        XCTAssertTrue(PetMilestones.isAnniversary(date(2024, 2, 29), on: date(2028, 2, 29), calendar: calendar))
        XCTAssertFalse(PetMilestones.isAnniversary(date(2026), on: date(2026), calendar: calendar, requiresAtLeastOneYear: true))
        XCTAssertTrue(PetMilestones.isAnniversary(date(2025), on: date(2026), calendar: calendar, requiresAtLeastOneYear: true))
    }

    func testCelebrationDoesNotImplyAgeAndReportedStageDoesNotChangeBehavior() {
        let pet = Pet(name: "Casper", species: .dog)
        pet.createdAt = date(2026)
        XCTAssertNil(pet.birthdate)
        XCTAssertEqual(pet.annualCelebrationDate, date(2026))
        XCTAssertNil(pet.lifeStage(on: date(2026)))
        XCTAssertTrue(pet.behaviorTags.isEmpty)
        // Day 0 salon registration does not trigger celebration
        XCTAssertFalse(pet.celebrationStatus(on: date(2026), calendar: calendar).isCelebrating)
        XCTAssertTrue(pet.celebrationStatus(on: date(2026), calendar: calendar).isHonorary)
        // One year later, anniversary triggers celebration
        XCTAssertTrue(pet.celebrationStatus(on: date(2027), calendar: calendar).isCelebrating)
        XCTAssertTrue(pet.celebrationStatus(on: date(2027), calendar: calendar).isHonorary)

        // When birthdate is provided, life stage is derived automatically
        pet.birthdate = date(2018)
        XCTAssertEqual(pet.annualCelebrationDate, date(2018))
        XCTAssertEqual(pet.lifeStage(on: date(2026)), .senior)
        XCTAssertTrue(pet.behaviorTags.isEmpty)
        XCTAssertTrue(pet.celebrationStatus(on: date(2026), calendar: calendar).isCelebrating)
        XCTAssertFalse(pet.celebrationStatus(on: date(2026), calendar: calendar).isHonorary)
    }

    func testActorSavesMilestonesAndPreservesConcurrentCareChanges() async throws {
        let schema = Schema(PawtrackrSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let owner = Client(firstName: "Test", lastName: "Owner")
        context.insert(owner)
        try context.save()
        let repository = PetEditorRepository(modelContainer: container)
        let id = try await repository.add(ownerID: owner.persistentModelID, data: NewPetData(name: "Casper", species: .dog, gender: .male, breed: "Yorkie", color: "Black", photoData: nil, health: "Existing care", behaviorTags: ["Calm"], birthdate: nil))
        let fresh = ModelContext(container)
        let pet = try XCTUnwrap(fresh.model(for: id) as? Pet)
        XCTAssertNil(pet.birthdate)
        XCTAssertEqual(pet.annualCelebrationDate, pet.createdAt)
        let baseline = PetEditFields(pet: pet)
        pet.health = "Updated care"
        pet.weightLbs = 0 // Legacy data must not block an unrelated profile edit.
        pet.behaviorTags = ["Aggressive"]
        try fresh.save()
        var edit = baseline
        edit.name = "Casper II"
        edit.birthdate = date(2010)
        let saved = try await PetEditorRepository(modelContainer: container).save(id: id, fields: edit, baseline: baseline)
        XCTAssertEqual(saved.name, "Casper II")
        XCTAssertEqual(saved.health, "Updated care")
        XCTAssertEqual(saved.behaviorTags, ["Aggressive"])
        XCTAssertEqual(saved.weight, 0)
        XCTAssertEqual(saved.birthdate, date(2010))
    }

    func testNewClientPersistsCelebrationWithoutInventingBirthdate() async throws {
        let schema = Schema(PawtrackrSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let vm = NewClientViewModel(modelContext: container.mainContext)
        vm.first = "Birthday"
        vm.last = "Owner"
        vm.phone = "3235550142"
        vm.pets[0].name = "Casper"
        vm.pets[0].hasBirthdate = false
        let outcome = await vm.createClient()
        XCTAssertEqual(outcome, .created)
        let fresh = ModelContext(container)
        let pet = try XCTUnwrap(fresh.fetch(FetchDescriptor<Pet>()).first)
        XCTAssertNil(pet.birthdate)
        XCTAssertEqual(pet.annualCelebrationDate, pet.createdAt)
        XCTAssertNil(pet.lifeStage(on: date(2026)))
    }

    func testNewClientPetAndContactRemoval() {
        let schema = Schema(PawtrackrSchema.models)
        let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let vm = NewClientViewModel(modelContext: container.mainContext)
        XCTAssertEqual(vm.pets.count, 1)
        let firstPetID = vm.pets[0].id
        vm.addPet()
        XCTAssertEqual(vm.pets.count, 2)
        let secondPetID = vm.pets[1].id
        vm.removePet(id: firstPetID)
        XCTAssertEqual(vm.pets.count, 1)
        XCTAssertEqual(vm.pets[0].id, secondPetID)
        // Cannot remove last pet
        vm.removePet(id: secondPetID)
        XCTAssertEqual(vm.pets.count, 1)

        XCTAssertEqual(vm.contacts.count, 1)
        let firstContactID = vm.contacts[0].id
        vm.removeContact(id: firstContactID)
        XCTAssertTrue(vm.contacts.isEmpty)
    }
}
