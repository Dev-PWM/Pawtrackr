#if DEBUG
import Foundation
import SwiftData

/// Fictional, alphabetic identities shared by search stress tests and opt-in UI automation.
/// The fixture refuses disk stores and never participates in a normal app launch.
enum ClientSearchStressFixture {
    struct Entry: Sendable {
        let first: String
        let last: String
        let phone: String
        let dog: String
        let breed: String
        let gender: PetGender
        let active: Bool
        let missingContact: Bool
        var fullName: String { "\(first) \(last)" }
    }

    struct Seeded: Sendable {
        let entry: Entry
        let id: PersistentIdentifier
        let uuid: UUID
    }

    static let entries: [Entry] = {
        let firstNames = [
            "Ava", "Adam", "Amelia", "Anna", "Benjamin", "Caleb", "Charlotte", "Chloe",
            "Daniel", "David", "Eleanor", "Elijah", "Elizabeth", "Emily", "Emma", "Ethan",
            "Evelyn", "Grace", "Hannah", "Henry", "Isabella", "Jack", "James", "Liam",
            "Lily", "Lucas", "Mason", "Mia", "Noah", "Nora", "Oliver", "Olivia", "Oscar",
            "Penelope", "Ruby", "Sarah", "Samuel", "Thomas", "Victoria", "Zoe"
        ]
        let lastNames = [
            "Adams", "Allen", "Baker", "Bennett", "Brooks", "Brown", "Clark", "Cooper",
            "Davis", "Evans", "Flores", "Garcia", "Green", "Harris", "Jackson", "Johnson",
            "King", "Lewis", "Martinez", "Miller", "Moore", "Nelson", "Smith", "Taylor", "Zimmerman"
        ]
        let femaleDogs = ["Luna", "Bella", "Daisy", "Ruby", "Lucy", "Molly", "Rosie", "Sadie", "Lola", "Willow"]
        let maleDogs = ["Max", "Charlie", "Cooper", "Buddy", "Milo", "Teddy", "Rocky", "Oliver", "Leo", "Toby"]
        let breeds = ["Poodle", "Labrador Retriever", "Golden Retriever", "Beagle", "Boxer",
                      "Corgi", "Dachshund", "German Shepherd", "Shih Tzu", "Siberian Husky"]
        return firstNames.flatMap { first in lastNames.map { (first, $0) } }.enumerated().map { index, name in
            Entry(first: name.0, last: name.1, phone: "202555" + String(format: "%04d", index),
                  dog: index.isMultiple(of: 2) ? femaleDogs[(index / 2) % 10] : maleDogs[(index / 2) % 10],
                  breed: breeds[(index / 3) % breeds.count], gender: index.isMultiple(of: 2) ? .female : .male,
                  active: index.isMultiple(of: 10), missingContact: index.isMultiple(of: 7))
        }
    }()

    /// Creates complete dog profiles on a background context, returning values rather than models.
    static func seed(in container: ModelContainer) async throws -> [Seeded] {
        guard container.configurations.allSatisfy(\.isStoredInMemoryOnly) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return try await ClientBackgroundQuery.run(container: container) { context in
            guard try context.fetchCount(FetchDescriptor<Client>()) == 0 else { return [] }
            var clients: [(Entry, Client)] = []
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                let client = Client(firstName: entry.first, lastName: entry.last, phone: entry.phone,
                                    email: "\(entry.first).\(entry.last)@example.invalid")
                client.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
                let dog = Pet(name: entry.dog, species: .dog, gender: entry.gender)
                dog.breed = entry.breed
                dog.color = index.isMultiple(of: 2) ? "Golden" : "Brown"
                dog.birthdate = Date(timeIntervalSince1970: 1_550_000_000 + TimeInterval(index * 86_400))
                dog.weightLbs = Decimal(10 + index % 70)
                context.insert(client)
                context.insert(dog)
                dog.owner = client
                if entry.active { context.insert(Visit(pet: dog)) }
                if !entry.missingContact {
                    let contact = EmergencyContact(name: "Morgan Reed", phone: "2025559999")
                    context.insert(contact)
                    contact.owner = client
                }
                clients.append((entry, client))
            }
            try context.save()
            return clients.map { Seeded(entry: $0.0, id: $0.1.persistentModelID, uuid: $0.1.uuid) }
        }
    }
}
#endif
