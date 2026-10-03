//
//  Client.swift
//  Pawtrackr
//
//  SwiftData model for a pet owner (client).
//
//  Created by mac on 8/14/25.
//  Updated by Assistant on 8/28/25.
//

import Foundation
import SwiftData

@Model
final class Client {
    #Index<Client>([\.lastName, \.firstName], [\.lastVisitDate], [\.phoneDigits], [\.normalizedNameKey], [\.searchKeysVersion])

    // MARK: - Identity & Timestamps
    // Initializers overwrite these persisted defaults when creating records.
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: UUID = DeviceIdentity.currentID

    // MARK: - Contact Information
    var firstName: String = ""
    var lastName: String = ""
    var phone: String?
    var phoneDigits: String = ""
    var normalizedNameKey: String = ""
    var searchKeysVersion: Int = 0
    var email: String?
    var address: String?
    var primaryContactInfo: String?
    @Attribute(.externalStorage) var photoData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    
    // MARK: - Notes & Emergency Contact
    var notes: String?
    var lastVisitDate: Date?
    var loyaltyPoints: Int = 0

    // MARK: - Relationships
    @Relationship(deleteRule: .cascade, inverse: \Pet.owner) var pets: [Pet]? = []
    @Relationship(deleteRule: .cascade, inverse: \EmergencyContact.owner) var emergencyContacts: [EmergencyContact]? = []
    var user: User?

    // MARK: - Init
    init(firstName: String, lastName: String, phone: String? = nil, email: String? = nil) {
        self.uuid = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.firstName = TextInputLimits.clamped(firstName, to: TextInputLimits.name)
        self.lastName = TextInputLimits.clamped(lastName, to: TextInputLimits.name)
        self.phone = TextInputLimits.clampedOptional(phone, to: TextInputLimits.phone)
        self.email = TextInputLimits.clampedOptional(email, to: TextInputLimits.email)?.lowercased()
        refreshSearchKeys()
        updatePrimaryContact()
    }

    // MARK: - Derived Properties
    
    /// The client's full name, created by joining the first and last names.
    var fullName: String {
        [firstName.trimmed, lastName.trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when any of this client's pets is flagged aggressive. Single source of
    /// truth for the staff-safety warning shown on the client list and detail.
    /// the current behavior tags.
    var hasAggressivePet: Bool {
        (pets ?? []).contains { $0.archivedAt == nil && $0.isAggressive }
    }
    
    var smsURL: URL? {
        guard let p = phone, let urlStr = PhoneUtils.smsURLString(p) else { return nil }
        return URL(string: urlStr)
    }
    
    var telURL: URL? {
        guard let p = phone, let urlStr = PhoneUtils.telURLString(p) else { return nil }
        return URL(string: urlStr)
    }
    
    /// Best-effort single-line contact summary.
    var primaryContact: String {
        if let info = primaryContactInfo, !info.isEmpty {
            return info
        }
        let parts = [phone?.trimmed, email?.trimmed].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.first ?? ""
    }

    // MARK: - Mutating API (keeps timestamps correct without property observers)
    //
    // Each setter compares before assigning. SwiftData marks a row changed on
    // any assignment, even of the same value, and every changed row uploads to
    // updatedAt/lastModifiedBy and look like a real edit from this device to
    // the edit-conflict check on the others.
    func setFirstName(_ value: String) {
        let newValue = TextInputLimits.clamped(value, to: TextInputLimits.name)
        guard firstName != newValue else { refreshSearchKeys(); return }
        firstName = newValue
        refreshSearchKeys()
        didUpdate(ownerDetailsChanged: true)
    }
    func setLastName(_ value: String) {
        let newValue = TextInputLimits.clamped(value, to: TextInputLimits.name)
        guard lastName != newValue else { refreshSearchKeys(); return }
        lastName = newValue
        refreshSearchKeys()
        didUpdate(ownerDetailsChanged: true)
    }
    func setPhone(_ value: String?) {
        let trimmed = TextInputLimits.clampedOptional(value, to: TextInputLimits.phone)
        let newValue: String?
        if let t = trimmed, !t.isEmpty {
            // Prefer canonical E.164. If the input doesn't parse, fall back to
            // the user's literal text — but `findClient(byPhone:)` normalizes
            // both stored and lookup values, so unparseable phones still match.
            newValue = PhoneUtils.toE164(t) ?? t
        } else {
            newValue = nil
        }
        guard phone != newValue else { refreshSearchKeys(); return }
        phone = newValue
        refreshSearchKeys()
        updatePrimaryContact()
        didUpdate(ownerDetailsChanged: true)
    }
    func setEmail(_ value: String?) {
        let trimmed = TextInputLimits.clampedOptional(value, to: TextInputLimits.email)
        let newValue = trimmed?.isEmpty == false ? trimmed?.lowercased() : nil
        guard email != newValue else { return }
        email = newValue
        updatePrimaryContact()
        didUpdate()
    }

    /// Repairs derived lookup keys without treating store maintenance as an owner edit.
    func refreshSearchKeys() {
        let digits = PhoneUtils.searchKey(phone ?? "")
        let name = Self.nameLookupKey(firstName: firstName, lastName: lastName)
        if phoneDigits != digits { phoneDigits = digits }
        if normalizedNameKey != name { normalizedNameKey = name }
        if searchKeysVersion != 1 { searchKeysVersion = 1 }
    }

    /// Produces a locale-stable exact full-name key, ignoring accents and extra spaces.
    static func nameLookupKey(firstName: String, lastName: String) -> String {
        (firstName + " " + lastName).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func setAddress(_ value: String?) {
        let trimmed = TextInputLimits.clampedOptional(value, to: TextInputLimits.address)
        let newValue = trimmed?.isEmpty == false ? trimmed : nil
        guard address != newValue else { return }
        address = newValue
        didUpdate()
    }
    func setNotes(_ value: String?) {
        let newValue = TextInputLimits.clampedOptional(value, to: TextInputLimits.notes)
        guard notes != newValue else { return }
        notes = newValue
        didUpdate()
    }
    func addPet(_ pet: Pet) {
        var currentPets = pets ?? []
        if !currentPets.contains(where: { $0 === pet }) {
            currentPets.append(pet)
            pets = currentPets
            didUpdate(ownerDetailsChanged: true)
        }
    }
    func removePet(_ pet: Pet) {
        var currentPets = pets ?? []
        if let idx = currentPets.firstIndex(where: { $0 === pet }) {
            currentPets.remove(at: idx)
            pets = currentPets
            didUpdate()
        }
    }

    func setPhotoData(_ data: Data?) {
        if let data = data {
            photoData = LocalMediaPolicy.optimizedFullImageData(data, context: AppLocalization.localized("media.client_photo", value: "client profile photo"))
            updateThumbnail()
        } else {
            photoData = nil
            thumbnailData = nil
        }
        didUpdate()
    }
    
    // MARK: - Private Helpers
    /// `ownerDetailsChanged`: the name or phone changed, or a pet was added.
    /// Pet items carry the owner's name and phone, so those re-index too.
    private func didUpdate(ownerDetailsChanged: Bool = false) {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
        // Snapshots on this thread, then debounces per id on the indexer's
        // queue, so a multi-field edit (name + phone + email) is one write.
        // Skipped entirely while App Lock keeps Pawtrackr out of Spotlight.
        SpotlightIndexer.shared.scheduleIndex(client: self, includingPets: ownerDetailsChanged)
    }

    func updateThumbnail() {
        guard let data = photoData else {
            thumbnailData = nil
            return
        }
        #if canImport(UIKit) || canImport(AppKit)
        thumbnailData = LocalMediaPolicy.optimizedThumbnailData(data)
        #endif
    }

    private func updatePrimaryContact() {
        let parts = [phone?.trimmed, email?.trimmed].compactMap { $0 }.filter { !$0.isEmpty }
        let newValue = parts.first ?? ""
        if primaryContactInfo != newValue { primaryContactInfo = newValue }
    }
}
