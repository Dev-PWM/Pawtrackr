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

    func testBirthdayTakesPriorityAndDoesNotMutateSavedDates() {
        let owner = Client(firstName: "Ava", lastName: "Martinez")
        owner.createdAt = date(2019)
        let pet = Pet(name: "Luna", species: .dog, gender: .female)
        pet.owner = owner
        pet.createdAt = date(2025)
        pet.birthdate = date(2023, 5, 6)
        XCTAssertNil(pet.celebration(on: date(2026), calendar: calendar))
        XCTAssertEqual(pet.celebration(on: date(2026, 5, 6), calendar: calendar), .birthday(age: 3))
        XCTAssertEqual(pet.createdAt, date(2025))
        XCTAssertEqual(owner.createdAt, date(2019))
        XCTAssertEqual(pet.birthdate, date(2023, 5, 6))
    }

    func testUnknownBirthdateUsesClientHistoryIncludingOtherPets() {
        let owner = Client(firstName: "Ava", lastName: "Martinez")
        owner.createdAt = date(2025)
        let pet = Pet(name: "Luna", species: .dog)
        pet.createdAt = date(2026)
        pet.owner = owner
        let other = Pet(name: "Milo", species: .dog)
        other.owner = owner
        owner.pets = [pet, other]
        let oldVisit = Visit(pet: other, startedAt: date(2020))
        oldVisit.endedAt = date(2020).addingTimeInterval(3600)
        let unfinished = Visit(pet: other, startedAt: date(2018))
        let future = Visit(pet: other, startedAt: date(2017))
        future.endedAt = date(2028)
        let invalid = Visit(pet: other, startedAt: date(2016))
        invalid.endedAt = date(2015)
        other.visits = [oldVisit, unfinished, future, invalid]
        XCTAssertEqual(pet.salonAnniversaryDate(on: date(2026)), date(2020))
        XCTAssertEqual(pet.celebration(on: date(2026), calendar: calendar), .salonAnniversary(years: 6))
        XCTAssertNil(pet.birthdate)
        XCTAssertNil(pet.lifeStage(on: date(2026)))
    }

    func testClientRegistrationAndFirstLeapDayAnniversary() {
        let owner = Client(firstName: "Ava", lastName: "Martinez")
        owner.createdAt = date(2024, 2, 29)
        let pet = Pet(name: "Luna", species: .dog)
        pet.createdAt = date(2024, 6, 1)
        pet.owner = owner
        XCTAssertEqual(pet.celebration(on: date(2025, 2, 28), calendar: calendar), .salonAnniversary(years: 1))
        XCTAssertNil(pet.celebration(on: date(2028, 2, 28), calendar: calendar))
        XCTAssertEqual(pet.celebration(on: date(2028, 2, 29), calendar: calendar), .salonAnniversary(years: 4))
        pet.birthdate = date(2024, 2, 29)
        XCTAssertEqual(pet.celebration(on: date(2025, 2, 28), calendar: calendar), .birthday(age: 1))
    }

    func testCelebrationChangesAtLocalMidnight() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let midnight = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let pet = Pet(name: "Luna", species: .dog)
        pet.birthdate = try XCTUnwrap(local.date(from: DateComponents(year: 2023, month: 10, day: 12)))
        XCTAssertNil(pet.celebration(on: midnight.addingTimeInterval(-1), calendar: local))
        XCTAssertEqual(pet.celebration(on: midnight, calendar: local), .birthday(age: 3))
        let nextDay = try XCTUnwrap(local.date(byAdding: .day, value: 1, to: midnight))
        XCTAssertNil(pet.celebration(on: nextDay, calendar: local))
        pet.birthdate = date(2027)
        XCTAssertNil(pet.celebration(on: midnight, calendar: local))
    }

    func testBirthdayAndAnniversaryCopyInBothLanguages() {
        let previous = UserDefaults.standard.object(forKey: AppSettingsKeys.appLanguageOverride)
        defer { UserDefaults.standard.set(previous, forKey: AppSettingsKeys.appLanguageOverride) }
        for language in [AppLanguageOverride.en, .es] {
            UserDefaults.standard.set(language.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
            let male = PetCelebrationCopy.title(.birthday(age: 3), name: "Milo", gender: .male)
            let female = PetCelebrationCopy.title(.birthday(age: 3), name: "Luna", gender: .female)
            let neutral = PetCelebrationCopy.title(.birthday(age: 3), name: "Pepper", gender: nil)
            XCTAssertTrue(male.contains("Milo"))
            XCTAssertTrue(female.contains("Luna"))
            XCTAssertTrue(neutral.contains("Pepper"))
            XCTAssertNotEqual(male.replacingOccurrences(of: "Milo", with: "Pet"),
                              female.replacingOccurrences(of: "Luna", with: "Pet"))
            let firstYear = PetCelebrationCopy.title(.salonAnniversary(years: 1), name: "Luna", gender: .female)
            let thirdYear = PetCelebrationCopy.title(.salonAnniversary(years: 3), name: "Luna", gender: .female)
            let thanks = PetCelebrationCopy.detail(.salonAnniversary(years: 3), clientName: "Ava Martinez")
            XCTAssertTrue(firstYear.contains("1"))
            XCTAssertTrue(thirdYear.contains("3"))
            XCTAssertTrue(thanks.contains("Ava Martinez"))
            XCTAssertFalse(PetCelebrationCopy.detail(.birthday(age: 0), clientName: nil).isEmpty)
        }
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
        XCTAssertEqual(pet.annualCelebrationDate, pet.salonAnniversaryDate())
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
        XCTAssertEqual(pet.annualCelebrationDate, pet.salonAnniversaryDate())
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
