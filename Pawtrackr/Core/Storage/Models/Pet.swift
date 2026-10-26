//
//  Pet.swift
//  Pawtrackr
//
//  SwiftData model for an animal belonging to a Client.
//
//  Created by mac on 8/14/25.
//  Updated by Assistant on 8/28/25.
//

import Foundation
import OSLog
import SwiftData

@Model
final class Pet {
    #Index<Pet>([\.createdAt], [\.name])

    // MARK: - Identity & Timestamps
    // partial records. Defaults must be fully qualified (the @Model macro
    // can't resolve `.now` / `.dog` / etc.). App init paths always overwrite.
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: UUID = DeviceIdentity.currentID

    // MARK: - Core Attributes
    var name: String = ""

    // Species & gender are stored as the enums' String rawValues, NOT the enums
    // themselves. A `Codable` enum stored directly becomes a SwiftData "composite
    // attribute" that fatally and uncatchably aborts every `[Pet]` fetch (which
    // back `@Query`-driven UI) if any record holds an undecodable value — e.g. a
    // `@Transient` view is decode-crash-proof (same pattern as `behaviorTags`).
    var speciesRaw: String = Species.dog.rawValue
    var genderRaw: String = PetGender.male.rawValue

    /// Non-persisted view over `speciesRaw`, preserving the `pet.species` API.
    /// `@Transient` is REQUIRED — without it the `@Model` macro still synthesizes
    /// the crashing composite attribute.
    @Transient
    var species: Species {
        get { Species(rawValue: speciesRaw) ?? .dog }
        set { speciesRaw = newValue.rawValue }
    }

    /// Non-persisted view over `genderRaw`, preserving the `pet.gender` API.
    @Transient
    var gender: PetGender {
        get { PetGender(rawValue: genderRaw) ?? .male }
        set { genderRaw = newValue.rawValue }
    }

    // MARK: - Optional Attributes
    var breed: String?
    var color: String?
    /// Removed pets retain ownership and visit history, but leave current lists.
    var archivedAt: Date?
    var birthdate: Date?
    @Attribute(.externalStorage) var photoData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    
    // MARK: - Notes & Behavior
    var notes: String?
    var health: String?
    var behaviorTagsRaw: String = ""
    var lastAttentionOutreachAt: Date?
    @Transient
    var behaviorTags: [String] {
        get { Self.decodeBehaviorTags(from: behaviorTagsRaw) }
        set { behaviorTagsRaw = Self.encodeBehaviorTags(newValue) }
    }
    var specialInstructions: String?

    // MARK: - Grooming & Vet Info
    var weightLbs: Decimal?

    /// Stored as the enum's String rawValue (decode-crash-proof; see `speciesRaw`).
    var preferredGroomingFrequencyRaw: String?

    /// Non-persisted view preserving the `pet.preferredGroomingFrequency` API.
    @Transient
    var preferredGroomingFrequency: GroomingFrequency? {
        get { preferredGroomingFrequencyRaw.flatMap(GroomingFrequency.init(rawValue:)) }
        set { preferredGroomingFrequencyRaw = newValue?.rawValue }
    }
    var veterinarianName: String?
    var veterinarianPhoneE164: String?

    // MARK: - Caching
    private var _cachedAgeString: String?
    private var _ageLastCalculated: Date?

    // MARK: - Relationships
    var owner: Client?
    @Relationship(deleteRule: .cascade, inverse: \Visit.pet) var visits: [Visit]? = []
    
    var user: User?
    var activeVisit: Visit? {
        (visits ?? []).first { $0.endedAt == nil }
    }

    /// True when the pet carries a behavior tag indicating a handling hazard.
    /// Drives the high-visibility red safety flags shown across the client
    /// center, pet detail, and pet cards so staff are warned before handling.
    var isAggressive: Bool {
        behaviorTags.contains { Pet.isAggressiveTag($0) }
    }

    /// Standing care needs remain independent of the latest temperament observation.
    var hasSpecialNeeds: Bool {
        behaviorTags.contains { Self.behaviorTagKind(for: $0) == .specialNeeds }
    }

    /// Safety takes precedence over temperament when choosing the card's visual cue.
    var prominentBehavior: BehaviorTag? {
        let kinds = Set(behaviorTags.compactMap(Self.behaviorTagKind(for:)))
        return [.aggressive, .specialNeeds, .anxious, .nervous, .cooperative, .calm]
            .first { kinds.contains($0) }
    }

    /// True when a behavior tag denotes aggression/danger, in English OR Spanish.
    /// Behavior tags are stored as their localized label (e.g. "Agresivo" on a
    /// Spanish device), so matching only English keywords misses them — which is
    /// why the red safety banner failed to appear on iPhone/iPad in Spanish. We
    /// fold away case and accents and match both languages' stems.
    static func isAggressiveTag(_ tag: String) -> Bool {
        let key = tag.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let needles = ["aggressive", "agresiv", "bite", "muerde", "muerd", "dangerous", "danger", "peligros"]
        return needles.contains { key.contains($0) }
    }

    struct AggressionClearanceStatus: Equatable, Sendable {
        let isAggressive: Bool
        let calmStreak: Int
        let requiredStreak: Int // 3

        var isCleared: Bool { !isAggressive }
        var isProbationary: Bool { isAggressive && calmStreak > 0 }
        var remainingVisits: Int { max(0, requiredStreak - calmStreak) }
    }

    /// Returns the pet's progress toward clearing an aggressive handling warning.
    ///
    /// When an aggressive flag is placed on a pet, they must complete 3 consecutive
    /// observed visits marked calm, cooperative, anxious, or nervous (without aggression)
    /// before the staff safety warning is retired.
    var aggressionClearanceStatus: AggressionClearanceStatus {
        let required = 3
        guard isAggressive else {
            return AggressionClearanceStatus(isAggressive: false, calmStreak: required, requiredStreak: required)
        }

        let completedSnapshots = Self.recentCompletedBehaviorTagSnapshots(from: visits ?? [])
        var streak = 0
        for snapshot in completedSnapshots {
            let cleaned = Self.cleanedBehaviorTags(snapshot.tags)
            if cleaned.isEmpty || cleaned.allSatisfy({ Self.behaviorTagKind(for: $0) == .specialNeeds }) {
                // Untagged visits neither advance nor break the clearance streak
                continue
            }
            if Self.containsAggressiveBehavior(in: cleaned) {
                break
            }
            if Self.isAggressionClearanceVisit(tags: cleaned) {
                streak += 1
                if streak >= required { break }
            } else {
                // Unknown observations do not establish a qualifying streak.
                break
            }
        }
        return AggressionClearanceStatus(isAggressive: true, calmStreak: streak, requiredStreak: required)
    }
    
    /// Returns a list of before/after photo pairs from completed visits.
    @Transient
    var transformationHistory: [(before: Data?, after: Data?, date: Date)] {
        (visits ?? [])
            .filter { $0.isCompleted }
            .sorted { $0.startedAt > $1.startedAt }
            .map { ($0.beforeThumbnailData ?? $0.beforePhotoData, $0.afterThumbnailData ?? $0.afterPhotoData, $0.startedAt) }
    }

    // MARK: - Business Intelligence (Lifetime Value & Trends)
    
    /// Total number of completed visits.
    var completedVisitCount: Int {
        (visits ?? []).filter { $0.isCompleted }.count
    }
    
    /// Total revenue generated by this pet.
    var lifetimeValue: Decimal {
        (visits ?? []).filter { $0.isCompleted }.reduce(Decimal.zero) { $0 + $1.total }
    }
    
    /// The date of the very first visit.
    var firstVisitDate: Date? {
        (visits ?? []).filter { $0.isCompleted }.map { $0.startedAt }.min()
    }
    
    /// Calculates the "Engagement Score" (0.0 to 1.0) based on visit frequency vs. preferred frequency.
    var engagementScore: Decimal {
        guard let avg = averageVisitInterval, let preferred = preferredGroomingFrequency else { return 0.5 }
        
        let preferredInterval: TimeInterval
        switch preferred {
        case .weekly: preferredInterval = 7 * 24 * 3600
        case .biWeekly: preferredInterval = 14 * 24 * 3600
        case .monthly: preferredInterval = 30 * 24 * 3600
        case .quarterly: preferredInterval = 90 * 24 * 3600
        case .asNeeded: return 1.0
        }
        
        // If they come more often than preferred, score is 1.0
        if avg <= preferredInterval { return 1.0 }
        
        // Otherwise, score decays as the interval lengthens
        let score = 1.0 - (avg - preferredInterval) / preferredInterval
        return max(0, Decimal(score))
    }

    // MARK: - Prediction Engine (Business Intelligence)

    /// Calculates the average time (in seconds) between completed visits.
    var averageVisitInterval: TimeInterval? {
        let completedVisits = (visits ?? [])
            .filter { $0.isCompleted }
            .sorted { $0.startedAt < $1.startedAt }
        
        guard completedVisits.count >= 2 else { return nil }
        
        var totalInterval: TimeInterval = 0
        for i in 1..<completedVisits.count {
            totalInterval += completedVisits[i].startedAt.timeIntervalSince(completedVisits[i-1].startedAt)
        }
        
        return totalInterval / TimeInterval(completedVisits.count - 1)
    }

    /// Default re-engagement cadence by species when the owner hasn't set an
    /// explicit preferred frequency. Dogs are typically groomed about once a
    /// month; cats far less often (they self-groom), so we wait ~6 months before
    /// nudging the owner.
    var defaultGroomingInterval: TimeInterval {
        switch species {
        case .dog: return 30 * 24 * 3600      // ~1 month
        case .cat: return 182 * 24 * 3600     // ~6 months
        }
    }

    /// Interval used to schedule the next-visit suggestion: an explicit owner
    /// preference wins, otherwise the species default. `nil` for `.asNeeded`.
    ///
    /// We intentionally do NOT key off `averageVisitInterval` here: a couple of
    /// closely-spaced visits (common during setup/testing) would otherwise flag
    /// the pet as overdue almost immediately and nag the owner far too soon.
    var suggestedGroomingInterval: TimeInterval? {
        if let preferred = preferredGroomingFrequency {
            switch preferred {
            case .weekly: return 7 * 24 * 3600
            case .biWeekly: return 14 * 24 * 3600
            case .monthly: return 30 * 24 * 3600
            case .quarterly: return 90 * 24 * 3600
            case .asNeeded: return nil
            }
        }
        return defaultGroomingInterval
    }

    /// Predicts the next suggested grooming date from the last completed visit
    /// and the species/preferred cadence.
    var suggestedNextVisitDate: Date? {
        if isCheckedIn { return nil }
        guard (visits ?? []).contains(where: { $0.isCompleted }) else { return nil }
        guard let lastVisitDate = (visits ?? []).compactMap({ $0.endedAt }).max() else { return nil }
        guard let interval = suggestedGroomingInterval else { return nil }
        return lastVisitDate.addingTimeInterval(interval)
    }

    /// Returns true if the pet is overdue for their next suggested visit.
    var isOverdue: Bool {
        guard let suggested = suggestedNextVisitDate else { return false }
        return Date() > suggested
    }

    /// Returns true when the dashboard/client center should flag this pet for outreach.
    /// Contacting the owner clears the flag until the next suggested visit becomes due.
    var needsAttention: Bool {
        guard isOverdue, let suggested = suggestedNextVisitDate else { return false }
        guard let lastAttentionOutreachAt else { return true }
        return lastAttentionOutreachAt < suggested
    }

    /// Human-readable string indicating when the next visit is expected or how overdue it is.
    var nextVisitStatus: String? {
        guard let suggested = suggestedNextVisitDate else { return nil }
        
        let now = Date()
        let cal = Calendar.current
        
        if now > suggested {
            let days = cal.dateComponents([.day], from: suggested, to: now).day ?? 0
            return days == 0
                ? AppLocalization.localized("pet.next_visit.due_today", value: "Due today")
                : String(format: AppLocalization.localized("pet.next_visit.overdue_fmt", value: "%dd overdue"), days)
        } else {
            let days = cal.dateComponents([.day], from: now, to: suggested).day ?? 0
            if days == 0 { return AppLocalization.localized("pet.next_visit.due_today", value: "Due today") }
            if days == 1 { return AppLocalization.localized("pet.next_visit.due_tomorrow", value: "Due tomorrow") }
            return String(format: AppLocalization.localized("pet.next_visit.due_in_fmt", value: "Due in %dd"), days)
        }
    }

    // MARK: - Init
    init(name: String, species: Species, gender: PetGender = .male) {
        self.uuid = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.name = name.trimmed
        self.speciesRaw = species.rawValue
        self.genderRaw = gender.rawValue
    }

    // MARK: - Derived Properties

    /// A boolean indicating if the pet is currently checked in.
    var isCheckedIn: Bool {
        activeVisit != nil
    }

    /// A user-friendly string describing the pet's age (e.g., "3yr 6mo", "9mo").
    var ageString: String? {
        let now = Date()
        if let lastCalculated = _ageLastCalculated,
           let cached = _cachedAgeString,
           Calendar.current.isDate(now, inSameDayAs: lastCalculated) {
            return cached
        }

        guard let birthdate = self.birthdate else { return nil }
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month], from: birthdate, to: now)

        let newAgeString: String?
        if let year = components.year, year > 0 {
            if let month = components.month, month > 0 {
                newAgeString = "\(year)yr \(month)mo"
            } else {
                newAgeString = "\(year)yr"
            }
        } else if let month = components.month, month > 0 {
            newAgeString = "\(month)mo"
        } else {
            newAgeString = nil
        }

        _cachedAgeString = newAgeString
        _ageLastCalculated = now
        return newAgeString
    }
    /// A short, descriptive string for UI display (e.g., "Golden Retriever • Dog").
    var shortDescriptor: String {
        if let breed = breed, !breed.trimmed.isEmpty {
            return "\(breed.trimmed) • \(species.displayName)"
        }
        return species.displayName
    }
    
    // MARK: - Mutating API (ensures timestamps are updated without property observers)
    func rename(_ newName: String) {
        name = newName.trimmed
        didUpdate()
    }

    func setSpecies(_ newSpecies: Species) {
        species = newSpecies
        didUpdate()
    }

    func setGender(_ newGender: PetGender) {
        gender = newGender
        didUpdate()
    }

    func setBreed(_ newBreed: String?) {
        breed = newBreed?.trimmed
        didUpdate()
    }

    func setColor(_ newColor: String?) {
        color = newColor?.trimmed
        didUpdate()
    }

    func setBirthdate(_ newDate: Date?) {
        if let date = newDate, date > Date() {
            // Silently ignore future dates or handle as error
            return
        }
        birthdate = newDate
        _cachedAgeString = nil
        _ageLastCalculated = nil
        didUpdate()
    }

    func setNotes(_ newNotes: String?) {
        notes = newNotes
        didUpdate()
    }

    func setHealth(_ newHealth: String?) {
        health = newHealth
        didUpdate()
    }

    func setBehaviorTags(_ tags: [String]) {
        behaviorTags = tags.map { $0.trimmed }.filter { !$0.isEmpty }
        didUpdate()
    }

    /// Reconciles the pet-level behavior tags from completed visit history after checkout.
    ///
    /// Aggressive handling is intentionally sticky for staff safety: a non-aggressive visit
    /// cannot clear the pet warning until the three most recent completed visits all contain
    /// calm/cooperative/anxious/nervous evidence and no aggressive/bite/danger evidence.
    func reconcileBehaviorTagsFromCompletedVisits(requiredClearVisitCount: Int = 3) {
        let completedVisitTags = Self.recentCompletedBehaviorTagSnapshots(from: visits ?? [])
        guard let latestVisitTags = completedVisitTags.first else { return }

        let careTags = behaviorTags.filter { Self.behaviorTagKind(for: $0) == .specialNeeds }
        let latestTags = Self.cleanedBehaviorTags(latestVisitTags.tags)
        // If the visit did not record any behavior tags, retain existing pet profile tags.
        guard !latestTags.isEmpty else { return }

        if latestTags.allSatisfy({ Self.behaviorTagKind(for: $0) == .specialNeeds }) {
            setBehaviorTags(Self.cleanedBehaviorTags(behaviorTags + latestTags))
            return
        }

        if Self.containsAggressiveBehavior(in: latestTags) {
            setBehaviorTags(Self.cleanedBehaviorTags(latestTags + careTags))
            return
        }

        guard isAggressive else {
            setBehaviorTags(Self.cleanedBehaviorTags(latestTags + careTags))
            return
        }

        let taggedSnapshots = completedVisitTags.filter {
            !$0.tags.isEmpty && !$0.tags.allSatisfy { Self.behaviorTagKind(for: $0) == .specialNeeds }
        }
        let required = max(1, requiredClearVisitCount)
        let recentClearanceWindow = Array(taggedSnapshots.prefix(required))
        let hasClearanceStreak = recentClearanceWindow.count == required
            && recentClearanceWindow.allSatisfy { Self.isAggressionClearanceVisit(tags: $0.tags) }

        if hasClearanceStreak {
            setBehaviorTags(Self.cleanedBehaviorTags(latestTags.filter { !Self.isAggressiveTag($0) } + careTags))
        } else {
            setBehaviorTags(Self.cleanedBehaviorTags(Self.tagsRetainingAggressiveWarning(existingTags: behaviorTags, latestTags: latestTags) + careTags))
        }
    }

    func addBehaviorTag(_ tag: String) {
        let t = tag.trimmed
        guard !t.isEmpty else { return }
        var tags = behaviorTags
        if !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            tags.append(t)
            behaviorTags = tags
            didUpdate()
        }
    }

    func removeBehaviorTag(_ tag: String) {
        let t = tag.trimmed
        var tags = behaviorTags
        if let idx = tags.firstIndex(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            tags.remove(at: idx)
            behaviorTags = tags
            didUpdate()
        }
    }

    func setSpecialInstructions(_ value: String?) {
        specialInstructions = value
        didUpdate()
    }

    func recordAttentionOutreach(at date: Date = .now) {
        lastAttentionOutreachAt = date
        didUpdate()
    }

    func setWeightLbs(_ value: Decimal?) {
        if let v = value { weightLbs = max(0, v) } else { weightLbs = nil }
        didUpdate()
    }

    func setPreferredGroomingFrequency(_ value: GroomingFrequency?) {
        preferredGroomingFrequency = value
        didUpdate()
    }

    func setVeterinarian(name: String?, phoneE164: String?) {
        veterinarianName = name?.trimmed
        veterinarianPhoneE164 = phoneE164?.trimmed
        didUpdate()
    }

    func setPhotoData(_ data: Data?) {
        if let data = data {
            photoData = LocalMediaPolicy.optimizedFullImageData(data, context: AppLocalization.localized("media.pet_photo", value: "pet profile photo"))
            updateThumbnail()
        } else {
            photoData = nil
            thumbnailData = nil
        }
        didUpdate()
    }
    
    // MARK: - Private Helpers
    private func didUpdate() {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
        // Snapshots on this thread (name, owner name and phone, thumbnail
        // only), then debounces per id on the indexer's queue. Skipped
        // entirely while App Lock keeps Pawtrackr out of Spotlight.
        SpotlightIndexer.shared.scheduleIndex(pet: self)
    }

    func updateThumbnail() {
        guard let data = photoData else {
            thumbnailData = nil
            return
        }
        // Downsample to a small thumbnail for high-performance list rendering.
        #if canImport(UIKit) || canImport(AppKit)
        thumbnailData = LocalMediaPolicy.optimizedThumbnailData(data)
        #endif
    }

    private static func decodeBehaviorTags(from raw: String) -> [String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            // Don't return [] — that would silently destroy the original on next save.
            // Instead, treat the raw string as a single legacy tag so downstream code
            // sees something to preserve and a human can untangle it later.
            Logger.dataIntegrity.error("Pet.behaviorTags JSON decode failed; preserving raw as single tag. error=\(error.localizedDescription, privacy: .public)")
            return [raw]
        }
    }

    private static func encodeBehaviorTags(_ tags: [String]) -> String {
        let cleaned = tags.map { $0.trimmed }.filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(cleaned),
              let raw = String(data: data, encoding: .utf8) else {
            return ""
        }
        return raw
    }
}

// MARK: - Nested Enums
extension Pet {
    /// Standardized options for grooming frequency.
    enum GroomingFrequency: String, Codable, CaseIterable, Identifiable {
        case weekly, biWeekly, monthly, quarterly, asNeeded
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .weekly:
                return AppLocalization.localized("pet.grooming_frequency.weekly", value: "Weekly")
            case .biWeekly:
                return AppLocalization.localized("pet.grooming_frequency.bi_weekly", value: "Every 2 Weeks")
            case .monthly:
                return AppLocalization.localized("pet.grooming_frequency.monthly", value: "Monthly")
            case .quarterly:
                return AppLocalization.localized("pet.grooming_frequency.quarterly", value: "Every 3 Months")
            case .asNeeded:
                return AppLocalization.localized("pet.grooming_frequency.as_needed", value: "As Needed")
            }
        }
    }
    
    /// Standardized, common behavior tags for consistent data entry.
    enum BehaviorTag: String, CaseIterable, Identifiable {
        case calm, cooperative, anxious, nervous, aggressive, specialNeeds
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .calm:
                return AppLocalization.localized("pet.behavior.calm", value: "Calm")
            case .cooperative:
                return AppLocalization.localized("pet.behavior.cooperative", value: "Cooperative")
            case .anxious:
                return AppLocalization.localized("pet.behavior.anxious", value: "Anxious")
            case .nervous:
                return AppLocalization.localized("pet.behavior.nervous", value: "Nervous")
            case .aggressive:
                return AppLocalization.localized("pet.behavior.aggressive", value: "Aggressive")
            case .specialNeeds:
                return AppLocalization.localized("pet.behavior.special_needs", value: "Special Needs")
            }
        }
    }

    /// Returns the standardized behavior kind represented by a raw user-facing tag.
    ///
    /// Tags may be persisted in the user's current language, so this recognizes the
    /// English and Spanish labels used by the app in addition to enum raw values.
    static func behaviorTagKind(for tag: String) -> BehaviorTag? {
        let key = behaviorTagLookupKey(tag)
        switch key {
        case "calm", "tranquilo", "tranquila":
            return .calm
        case "cooperative", "cooperativo", "cooperativa":
            return .cooperative
        case "anxious", "ansioso", "ansiosa":
            return .anxious
        case "nervous", "nervioso", "nerviosa":
            return .nervous
        case "specialneeds", "necesidadesespeciales", "necesidadespeciales", "necesidadespecial":
            return .specialNeeds
        default:
            return isAggressiveTag(tag) ? .aggressive : nil
        }
    }

    /// Returns true when a visit tag counts as positive de-escalation evidence.
    static func isCalmOrCooperativeTag(_ tag: String) -> Bool {
        guard let kind = behaviorTagKind(for: tag) else { return false }
        return kind == .calm || kind == .cooperative
    }

    /// An explicit non-aggressive observation counts once per completed visit.
    static func isNonAggressiveObservation(_ tag: String) -> Bool {
        switch behaviorTagKind(for: tag) {
        case .calm, .cooperative, .anxious, .nervous: return true
        default: return false
        }
    }

    /// Returns true when any supplied tag denotes aggressive, bite, or danger behavior.
    static func containsAggressiveBehavior(in tags: [String]) -> Bool {
        tags.contains { isAggressiveTag($0) }
    }

    /// Trims behavior tags and removes duplicates while preserving first-seen order.
    static func cleanedBehaviorTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var cleaned: [String] = []

        for tag in tags {
            let trimmed = tag.trimmed
            guard !trimmed.isEmpty else { continue }
            let key = tagUniquenessKey(trimmed)
            if seen.insert(key).inserted {
                cleaned.append(trimmed)
            }
        }

        return cleaned
    }

    private struct BehaviorVisitSnapshot {
        let uuid: UUID
        let sortDate: Date
        let createdAt: Date
        let tags: [String]
    }

    private static func recentCompletedBehaviorTagSnapshots(from visits: [Visit]) -> [BehaviorVisitSnapshot] {
        visits
            .filter(\.isCompleted)
            .map {
                BehaviorVisitSnapshot(
                    uuid: $0.uuid,
                    sortDate: $0.endedAt ?? $0.startedAt,
                    createdAt: $0.createdAt,
                    tags: cleanedBehaviorTags($0.behaviorTags)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.uuid.uuidString > rhs.uuid.uuidString
            }
    }

    private static func isAggressionClearanceVisit(tags: [String]) -> Bool {
        let cleaned = cleanedBehaviorTags(tags)
        return !containsAggressiveBehavior(in: cleaned) && cleaned.contains { isNonAggressiveObservation($0) }
    }

    private static func tagsRetainingAggressiveWarning(existingTags: [String], latestTags: [String]) -> [String] {
        let aggressiveTag = existingTags.first(where: { isAggressiveTag($0) }) ?? BehaviorTag.aggressive.displayName
        // Show today's observation without hiding the standing safety warning.
        let otherTags = latestTags.filter { !isAggressiveTag($0) }
        return cleanedBehaviorTags([aggressiveTag] + otherTags)
    }

    private static func behaviorTagLookupKey(_ tag: String) -> String {
        let folded = tag.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let allowed = CharacterSet.alphanumerics
        let scalars = folded.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func tagUniquenessKey(_ tag: String) -> String {
        tag.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
