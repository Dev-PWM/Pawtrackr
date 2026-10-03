import Foundation
import SwiftData

struct ClientDuplicateMatch: Sendable, Equatable {
    enum Reason: Sendable, Equatable { case phone, fullName }
    let id: PersistentIdentifier
    let reason: Reason
}

struct ClientDuplicateError: Error, Sendable {
    let match: ClientDuplicateMatch
}

struct ClientCreationInput: Sendable {
    let firstName: String
    let lastName: String
    let phone: String
    let email: String
    let address: String
    let photoData: Data?
    let pets: [NewPetData]
    let contacts: [NewContactData]
}

/// Serializes creation across every form/window, including the final duplicate check.
actor ClientCreationCoordinator {
    static let shared = ClientCreationCoordinator()
    private var isWriting = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Prepares additive lookup keys off the main actor; never changes owner timestamps.
    func prepare(container: ModelContainer) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await ClientCreationWriter(modelContainer: container).prepareSearchKeys()
    }

    /// Acquires the store-wide creation gate before constructing the background model actor.
    func create(container: ModelContainer, input: ClientCreationInput) async throws -> PersistentIdentifier {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await ClientCreationWriter(modelContainer: container).create(input)
    }

    /// Suspends competing creators without blocking a thread or retaining model containers.
    private func acquire() async {
        if !isWriting { isWriting = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Gives the next queued creator exclusive access after the previous transaction ends.
    private func release() {
        if waiting.isEmpty { isWriting = false }
        else { waiting.removeFirst().resume() }
    }
}

@ModelActor
private actor ClientCreationWriter {
    /// Backfills old stores in bounded batches; derived fields are the only fields changed.
    func prepareSearchKeys() throws {
        var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.searchKeysVersion == 0 })
        descriptor.fetchLimit = 200
        while true {
            try Task.checkCancellation()
            let clients = try modelContext.fetch(descriptor)
            guard !clients.isEmpty else { return }
            for client in clients { client.refreshSearchKeys() }
            do { try modelContext.save() }
            catch { modelContext.rollback(); throw error }
        }
    }

    /// Checks indexed phone/full-name keys and inserts the complete client atomically.
    func create(_ input: ClientCreationInput) throws -> PersistentIdentifier {
        try prepareSearchKeys()
        if let duplicate = try ClientDuplicateLookup.find(in: modelContext, firstName: input.firstName, lastName: input.lastName, phone: input.phone) {
            throw ClientDuplicateError(match: duplicate)
        }
        let firstName = input.firstName, lastName = input.lastName, phone = input.phone
        let email = input.email, address = input.address, photoData = input.photoData
        let pets = input.pets, contacts = input.contacts
        let client = Client(firstName: firstName, lastName: lastName)
        client.setPhone(phone)
        client.setEmail(email)
        client.setAddress(address)
        client.setPhotoData(photoData)
        modelContext.insert(client)

        for pd in pets {
            let pet = Pet(name: pd.name, species: pd.species, gender: pd.gender)
            pet.breed = pd.breed
            pet.color = pd.color
            pet.setPhotoData(pd.photoData)
            pet.updateThumbnail()
            pet.notes = pd.health
            pet.behaviorTags = pd.behaviorTags
            pet.birthdate = pd.birthdate
            pet.owner = client
            modelContext.insert(pet)
        }

        var emergencyContacts: [EmergencyContact] = []
        for cd in contacts {
            let contact = EmergencyContact(name: cd.name, relation: cd.relation, phone: cd.phone)
            contact.owner = client
            modelContext.insert(contact)
            emergencyContacts.append(contact)
        }
        client.emergencyContacts = emergencyContacts

        modelContext.insert(AppNotification(
            title: AppLocalization.localized("clients.notification.client_created_title", value: "Client Created"),
            message: client.fullName,
            sourceKey: "client-created-\(client.uuid)"
        ))
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        // The setters above indexed the client before its pets were attached,
        // and each pet before it had an owner. Index the saved state so the
        // client shows its pets and each pet is found by the owner's phone.
        SpotlightIndexer.shared.scheduleIndex(client: client, includingPets: true)
        return client.persistentModelID
    }
}

/// Uses non-unique indexes: existing records are never merged or discarded during upgrades.
enum ClientDuplicateLookup {
    /// Returns an exact phone hit before an exact normalized full-name hit.
    static func find(in context: ModelContext, firstName: String, lastName: String, phone: String) throws -> ClientDuplicateMatch? {
        let digits = PhoneUtils.searchKey(phone)
        if !digits.isEmpty {
            var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.phoneDigits == digits })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                return ClientDuplicateMatch(id: existing.persistentModelID, reason: .phone)
            }
        }
        let name = Client.nameLookupKey(firstName: firstName, lastName: lastName)
        guard !name.isEmpty else { return nil }
        var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.normalizedNameKey == name })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return ClientDuplicateMatch(id: existing.persistentModelID, reason: .fullName)
        }
        return nil
    }
}
