import Foundation

/// Simple grooming cues, not a diagnosis. Dog age boundaries vary by breed and size.
enum PetLifeStage: String, CaseIterable, Sendable {
    case young, adult, senior

    /// Returns species-appropriate, localized wording.
    func title(for species: Species) -> String {
        switch self {
        case .young: return species == .cat
            ? AppLocalization.localized("pet.stage.kitten", value: "Kitten")
            : AppLocalization.localized("pet.stage.puppy", value: "Puppy")
        case .adult: return AppLocalization.localized("pet.stage.adult", value: "Adult")
        case .senior: return AppLocalization.localized("pet.stage.senior", value: "Senior")
        }
    }

    /// Offers a broad age cue: under one, adult, or senior (8+ dogs / 11+ cats).
    /// AAHA's public senior-care guidance uses dogs older than 7 and cats older than 10.
    /// This automatic cue remains an estimate because canine maturity varies.
    static func estimate(birthdate: Date?, species: Species, on date: Date, calendar: Calendar = .current) -> Self? {
        guard let birthdate, calendar.startOfDay(for: birthdate) <= calendar.startOfDay(for: date) else { return nil }
        let years = calendar.dateComponents([.year], from: calendar.startOfDay(for: birthdate), to: calendar.startOfDay(for: date)).year ?? 0
        if years < 1 { return .young }
        return years >= (species == .cat ? 11 : 8) ? .senior : .adult
    }
}

/// Calendar-based celebration matching, independent of age calculation.
enum PetMilestones {
    /// Celebrates February 29 on February 28 in non-leap years, in the local calendar.
    /// When requiresAtLeastOneYear is true, day-0 registrations do not trigger an anniversary.
    static func isAnniversary(_ anniversary: Date?, on date: Date, calendar: Calendar = .current, requiresAtLeastOneYear: Bool = false) -> Bool {
        guard let anniversary, calendar.startOfDay(for: anniversary) <= calendar.startOfDay(for: date) else { return false }
        let original = calendar.dateComponents([.month, .day], from: anniversary)
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        let matches = (original.month == today.month && original.day == today.day)
            || (original.month == 2 && original.day == 29 && today.month == 2 && today.day == 28
                && calendar.range(of: .day, in: .month, for: date)?.count == 28)
        guard matches else { return false }
        return !requiresAtLeastOneYear || celebrationYears(since: anniversary, on: date, calendar: calendar) >= 1
    }

    /// Counts years on the observed anniversary, including February 28 for leap-day registrations.
    static func celebrationYears(since start: Date, on date: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.component(.year, from: date) - calendar.component(.year, from: start))
    }
}

/// A presentation milestone; never stored on a SwiftData model and never used to infer a birthdate.
enum PetCelebration: Hashable, Sendable {
    case birthday(age: Int)
    case salonAnniversary(years: Int)
}

extension Pet {
    /// Derives the stage on demand so it advances with age and never needs manual updates.
    func lifeStage(on date: Date = .now) -> PetLifeStage? {
        PetLifeStage.estimate(birthdate: birthdate, species: species, on: date)
    }

    /// Uses the real birthday when known, otherwise the client’s earliest salon relationship.
    /// The fallback is only for celebrating; it never participates in age calculations.
    var annualCelebrationDate: Date { birthdate ?? salonAnniversaryDate() }

    /// Uses the earliest evidence of this client's salon relationship, ignoring unfinished/future visits.
    func salonAnniversaryDate(on date: Date = .now) -> Date {
        let pets = [self] + (owner?.pets ?? []).filter { $0.uuid != uuid }
        let visits = pets.flatMap { $0.visits ?? [] }.filter { visit in
            guard let endedAt = visit.endedAt else { return false }
            return endedAt <= date && visit.startedAt <= endedAt
        }
        return ([createdAt] + [owner?.createdAt].compactMap { $0 } + visits.map(\.startedAt)).min() ?? createdAt
    }

    /// Gives a factual birthday priority; an unknown birthday celebrates client tenure after year one.
    func celebration(on date: Date = .now, calendar: Calendar = .current) -> PetCelebration? {
        let anchor = birthdate ?? salonAnniversaryDate(on: date)
        guard PetMilestones.isAnniversary(anchor, on: date, calendar: calendar,
                                         requiresAtLeastOneYear: birthdate == nil) else { return nil }
        let years = PetMilestones.celebrationYears(since: anchor, on: date, calendar: calendar)
        return birthdate == nil ? .salonAnniversary(years: years) : .birthday(age: years)
    }

    struct CelebrationStatus: Equatable, Sendable {
        let isCelebrating: Bool
        let isHonorary: Bool
    }

    /// True on the pet's birthday, or on the annual anniversary of joining the salon (after at least 1 year).
    func celebrationStatus(on date: Date = .now, calendar: Calendar = .current) -> CelebrationStatus {
        CelebrationStatus(isCelebrating: celebration(on: date, calendar: calendar) != nil, isHonorary: birthdate == nil)
    }
}
