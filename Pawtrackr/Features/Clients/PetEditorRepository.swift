import Foundation
import SwiftData

/// Sendable editor buffer that preserves legacy care fields outside the profile form.
struct PetEditFields: Equatable, Sendable {
    var name: String
    var species: Species
    var gender: PetGender
    var breed: String
    var color: String
    var birthdate: Date?
    var weight: Decimal?
    var notes: String
    var health: String
    var instructions: String
    var behaviorTags: [String]
    var photoData: Data?

    /// Snapshots editable fields without exposing a SwiftData object across actors.
    init(pet: Pet) {
        name = pet.name; species = pet.species; gender = pet.gender
        breed = pet.breed ?? ""; color = pet.color ?? ""
        birthdate = pet.birthdate; weight = pet.weightLbs
        notes = pet.notes ?? ""; health = pet.health ?? ""
        instructions = pet.specialInstructions ?? ""
        behaviorTags = pet.behaviorTags; photoData = pet.photoData
    }

    /// Applies only edited fields, preserving concurrent changes to untouched fields.
    func apply(to pet: Pet, changedFrom baseline: PetEditFields) {
        if name != baseline.name { pet.name = TextInputLimits.clamped(name, to: TextInputLimits.name) }
        if species != baseline.species { pet.species = species }
        if gender != baseline.gender { pet.gender = gender }
        if breed != baseline.breed { pet.breed = TextInputLimits.clampedOptional(breed, to: TextInputLimits.shortText) }
        if color != baseline.color { pet.color = TextInputLimits.clampedOptional(color, to: TextInputLimits.shortText) }
        if birthdate != baseline.birthdate { pet.setBirthdate(birthdate) }
        if weight != baseline.weight { pet.weightLbs = weight }
        if notes != baseline.notes { pet.notes = TextInputLimits.clampedOptional(notes, to: TextInputLimits.notes) }
        if health != baseline.health { pet.health = TextInputLimits.clampedOptional(health, to: TextInputLimits.notes) }
        if instructions != baseline.instructions { pet.specialInstructions = TextInputLimits.clampedOptional(instructions, to: TextInputLimits.notes) }
        if behaviorTags != baseline.behaviorTags { pet.setBehaviorTags(behaviorTags) }
        if photoData != baseline.photoData { pet.setPhotoData(photoData) }
    }
}

@ModelActor
actor PetEditorRepository {
    /// Creates a pet and its inbox entry in one serialized transaction.
    func add(ownerID: PersistentIdentifier, data: NewPetData) throws -> PersistentIdentifier {
        guard let owner = modelContext.model(for: ownerID) as? Client else {
            throw AppError.database(AppLocalization.localized("pet.editor.missing_owner", value: "This client is no longer available."))
        }
        let pet = Pet(name: data.name, species: data.species, gender: data.gender)
        pet.breed = data.breed; pet.color = data.color
        pet.health = data.health; pet.birthdate = data.birthdate
        pet.behaviorTags = data.behaviorTags
        pet.owner = owner
        modelContext.insert(pet)
        pet.setPhotoData(data.photoData)
        if !(owner.pets ?? []).contains(where: { $0.uuid == pet.uuid }) {
            owner.pets = (owner.pets ?? []) + [pet]
        }
        modelContext.insert(AppNotification(
            title: AppLocalization.localized("pet.notification.created", value: "Pet Added"),
            message: "\(pet.name) · \(owner.fullName)", sourceKey: "pet-created-\(pet.uuid)"
        ))
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        SpotlightIndexer.shared.scheduleIndex(client: owner, includingPets: true)
        return pet.persistentModelID
    }

    /// Saves changed editor fields and returns the committed state for UI refresh.
    func save(id: PersistentIdentifier, fields: PetEditFields, baseline: PetEditFields) throws -> PetEditFields {
        guard let pet = modelContext.model(for: id) as? Pet else {
            throw AppError.database(AppLocalization.localized("pet.editor.missing", value: "This pet is no longer available."))
        }
        guard !fields.name.trimmed.isEmpty else {
            throw AppError.validation(.custom(message: AppLocalization.localized("add_pet.name_empty", value: "Enter a pet name.")))
        }
        if fields.weight != baseline.weight, let weight = fields.weight, weight <= 0 {
            throw AppError.validation(.custom(message: AppLocalization.localized("pet.editor.invalid_weight", value: "Enter a weight greater than zero.")))
        }
        fields.apply(to: pet, changedFrom: baseline)
        pet.updatedAt = .now
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        if let owner = pet.owner { SpotlightIndexer.shared.scheduleIndex(client: owner, includingPets: true) }
        return PetEditFields(pet: pet)
    }

    /// Removes a pet from current workflows while preserving all history and ownership.
    /// An open session must be checked out before removal.
    func setRemoved(id: PersistentIdentifier, removed: Bool) throws -> Date? {
        guard let pet = modelContext.model(for: id) as? Pet else {
            throw AppError.database(AppLocalization.localized("pet.editor.missing", value: "This pet is no longer available."))
        }
        if removed {
            let open = try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.endedAt == nil }))
            guard !open.contains(where: { $0.pet?.persistentModelID == id }) else {
                throw AppError.validation(.custom(message: AppLocalization.localized("pet.editor.active_session", value: "Check out this pet's active session before removing it.")))
            }
        }
        pet.archivedAt = removed ? .now : nil
        pet.updatedAt = .now
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        if removed { SpotlightIndexer.shared.removePetFromIndex(petID: pet.uuid) }
        else { SpotlightIndexer.shared.scheduleIndex(pet: pet) }
        if let owner = pet.owner { SpotlightIndexer.shared.scheduleIndex(client: owner) }
        return pet.archivedAt
    }
}
