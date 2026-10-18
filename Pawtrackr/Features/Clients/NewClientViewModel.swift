//
//  NewClientViewModel.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-12-05.
//

import SwiftUI
import SwiftData
import Observation
import PhotosUI
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class NewClientViewModel {
    enum CreateClientOutcome: Equatable {
        case created
        case duplicateFound
        case failed
    }

    enum Field: String, Hashable {
        case first
        case last
        case phone
        case email
    }

    var first = ""
    var last  = ""
    var phone = ""
    var email = ""
    var address = ""

    var contacts: [TempContact] = [TempContact(index: 1)]
    var pets: [TempPet] = [TempPet(index: 1)]

    var appError: AppError? = nil
    var isSaving: Bool = false
    var showDuplicateAlert: Bool = false
    var duplicateClientID: PersistentIdentifier? = nil
    private(set) var createdClientID: PersistentIdentifier? = nil
    private(set) var fieldErrors: [Field: String] = [:]
    /// Inline errors for emergency contact rows, keyed by the row's id.
    private(set) var contactFieldErrors: [ContactFieldKey: String] = [:]

    struct ContactFieldKey: Hashable {
        let contactID: UUID
        let field: EmergencyContactRules.Field
    }

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let repository: ClientRepositoryProtocol
    
    init(modelContext: ModelContext, repository: ClientRepositoryProtocol? = nil) {
        self.modelContext = modelContext
        self.repository = repository ?? ClientRepository(modelContainer: modelContext.container)
    }

    func addPet() {
        pets.append(TempPet(index: pets.count + 1))
    }

    func removePet(id: UUID) {
        guard pets.count > 1 else { return }
        pets.removeAll { $0.id == id }
    }

    func addContact() {
        contacts.append(TempContact(index: contacts.count + 1))
    }

    func removeContact(id: UUID) {
        contacts.removeAll { $0.id == id }
        contactFieldErrors = contactFieldErrors.filter { $0.key.contactID != id }
    }

    func createClient() async -> CreateClientOutcome {
        Logger.newClient.info(
            "createClient enter: firstLength=\(self.first.count, privacy: .public) lastLength=\(self.last.count, privacy: .public) phonePresent=\(!self.phone.trimmed.isEmpty, privacy: .public) isSaving=\(self.isSaving, privacy: .public)"
        )
        guard !isSaving else {
            Logger.newClient.warning("createClient ignored because a save is already in progress")
            return .failed
        }
        isSaving = true
        appError = nil
        createdClientID = nil
        duplicateClientID = nil
        showDuplicateAlert = false

        defer { isSaving = false }

        do {
            try validate()
            Logger.newClient.info("createClient: validation passed")

            let e164 = PhoneUtils.toE164(phone)
            Logger.newClient.info("createClient: normalizedPhonePresent=\((e164 != nil), privacy: .public); checking duplicates")
            if let match = try await repository.findDuplicateClient(firstName: first.capitalizedName, lastName: last.capitalizedName, phone: e164 ?? "") {
                return reportDuplicate(match)
            }

            let newPets = pets.compactMap { tp -> NewPetData? in
                let petName = TextInputLimits.clamped(tp.name.capitalizedName, to: TextInputLimits.name)
                guard !petName.isEmpty, let gender = tp.gender else { return nil }
                return NewPetData(
                    name: petName,
                    species: tp.species,
                    gender: gender,
                    breed: TextInputLimits.clampedOptional(tp.breed.capitalizedName, to: TextInputLimits.shortText),
                    color: TextInputLimits.clampedOptional(tp.color.trimmed.lowercased(), to: TextInputLimits.shortText),
                    photoData: tp.photoData,
                    health: TextInputLimits.clampedOptional(tp.health, to: TextInputLimits.notes),
                    behaviorTags: tp.behaviorTags.map { TextInputLimits.limited($0, to: TextInputLimits.shortText) },
                    birthdate: tp.hasBirthdate ? tp.birthdate : nil
                )
            }

            let newContacts = try Self.contactData(from: contacts)

            let clientID = try await repository.createClient(
                firstName: TextInputLimits.clamped(first.capitalizedName, to: TextInputLimits.name),
                lastName: TextInputLimits.clamped(last.capitalizedName, to: TextInputLimits.name),
                phone: e164 ?? "",
                email: TextInputLimits.clamped(email.trimmed.lowercased(), to: TextInputLimits.email),
                address: TextInputLimits.clamped(address, to: TextInputLimits.address),
                photoData: nil,
                pets: newPets,
                contacts: newContacts
            )
            Logger.newClient.info("createClient: saved client through repository")
            createdClientID = clientID

            NotificationCenter.default.post(name: .clientDidCreate, object: nil, userInfo: [
                ClientDidCreateKey.clientID.rawValue: clientID,
                ClientDidCreateKey.phase.rawValue: ClientDidCreatePhase.created.rawValue
            ])

            HapticManager.notify(.success)
            Logger.newClient.info("createClient: returning .created")
            return .created
        } catch let error as ClientDuplicateError {
            return reportDuplicate(error.match)
        } catch let error as ValidationError {
            Logger.newClient.error("createClient: validation failed: \(error.localizedDescription, privacy: .public)")
            self.appError = .validation(error)
            HapticManager.notify(.error)
            return .failed
        } catch {
            Logger.newClient.error("createClient: save/db error: \(String(describing: error), privacy: .private)")
            Logger.database.error("Local save failed: \(error.localizedDescription, privacy: .public)")
            self.appError = .database(error.localizedDescription)
            HapticManager.notify(.error)
            return .failed
        }
    }

    /// Leaves the form intact and identifies the existing owner when either exact key matches.
    private func reportDuplicate(_ match: ClientDuplicateMatch) -> CreateClientOutcome {
        duplicateClientID = match.id
        showDuplicateAlert = true
        let message: String
        if match.reason == .phone {
            message = AppLocalization.localized("new_client.duplicate_phone", value: "A client with this phone number already exists.")
            fieldErrors[.phone] = message
        } else {
            message = AppLocalization.localized("new_client.duplicate_name", value: "A client with this full name already exists. Edit the existing client to add pets or update their information.")
            fieldErrors[.first] = message
            fieldErrors[.last] = message
        }
        appError = .validation(.custom(message: message))
        HapticManager.notify(.error)
        return .duplicateFound
    }

    private func validate() throws {
        fieldErrors.removeAll()
        if first.trimmed.isEmpty {
            fieldErrors[.first] = NSLocalizedString("new_client.validation.first_required", value: "First name is required.", comment: "")
        }
        if last.trimmed.isEmpty {
            fieldErrors[.last] = NSLocalizedString("new_client.validation.last_required", value: "Last name is required.", comment: "")
        }
        if !phone.trimmed.isEmpty && PhoneUtils.toE164(phone) == nil {
            fieldErrors[.phone] = NSLocalizedString("new_client.validation.phone_invalid", value: "Please enter a valid phone number.", comment: "")
        }
        if !email.trimmed.isEmpty && !isValidEmail(email) {
            fieldErrors[.email] = NSLocalizedString("new_client.validation.email_invalid", value: "Please enter a valid email address.", comment: "")
        }

        contactFieldErrors.removeAll()
        var firstContactError: String?
        for contact in contacts {
            if case let .invalid(field, message) = EmergencyContactRules.evaluate(name: contact.name, phone: contact.phone) {
                contactFieldErrors[ContactFieldKey(contactID: contact.id, field: field)] = message
                if firstContactError == nil { firstContactError = message }
            }
        }

        if let firstError = fieldErrors[.first] ?? fieldErrors[.last] ?? fieldErrors[.phone] ?? fieldErrors[.email] ?? firstContactError {
            throw ValidationError.custom(message: firstError)
        }
    }

    /// Every contact row the groomer typed becomes a contact. An empty row is
    /// skipped. A row that isn't valid throws rather than being left out, so
    /// the client never saves without a contact that was on the form.
    static func contactData(from rows: [TempContact]) throws -> [NewContactData] {
        try rows.compactMap { row -> NewContactData? in
            switch EmergencyContactRules.evaluate(name: row.name, phone: row.phone) {
            case .blank:
                return nil
            case .invalid(_, let message):
                throw ValidationError.custom(message: message)
            case .valid(let storedPhone):
                let relation = row.relation.trimmed.lowercased()
                return NewContactData(
                    name: TextInputLimits.limited(row.name.capitalizedName, to: TextInputLimits.name),
                    relation: TextInputLimits.clampedOptional(relation, to: TextInputLimits.shortText),
                    phone: storedPhone
                )
            }
        }
    }

    func validationError(for field: Field) -> String? {
        fieldErrors[field]
    }

    func clearValidationError(for field: Field) {
        guard fieldErrors[field] != nil else { return }
        fieldErrors.removeValue(forKey: field)
    }

    func contactValidationError(for contactID: UUID, field: EmergencyContactRules.Field) -> String? {
        contactFieldErrors[ContactFieldKey(contactID: contactID, field: field)]
    }

    /// Editing either field of a row can fix either message (a name fixes
    /// "add a name", clearing the phone fixes it too), so both are cleared.
    func clearContactValidationErrors(for contactID: UUID) {
        let nameKey = ContactFieldKey(contactID: contactID, field: .name)
        let phoneKey = ContactFieldKey(contactID: contactID, field: .phone)
        guard contactFieldErrors[nameKey] != nil || contactFieldErrors[phoneKey] != nil else { return }
        contactFieldErrors = contactFieldErrors.filter { $0.key.contactID != contactID }
    }

    private func isValidEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension Logger {
    static let newClient = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "NewClient")
}

// Temporary structs for form data
struct TempPet: Identifiable {
    let id = UUID()
    var index: Int
    var name = ""
    var species: Species = .dog
    var gender: PetGender? = .male
    var breed = ""
    var color = ""
    var health = ""
    var behaviorTags: Set<String> = []
    var photoData: Data? = nil
    var knownBirthdate: Date? {
        get { hasBirthdate ? birthdate : nil }
        set { hasBirthdate = newValue != nil; if let newValue { birthdate = newValue } }
    }
    var hasBirthdate: Bool = false
    var birthdate: Date = Date()
}

struct TempContact: Identifiable {
    let id = UUID()
    var index: Int
    var name: String = ""
    var relation: String = ""
    var phone: String = ""
}

#if os(macOS)
extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif
