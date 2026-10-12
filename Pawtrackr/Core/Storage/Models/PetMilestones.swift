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
        if requiresAtLeastOneYear {
            let years = calendar.dateComponents([.year], from: calendar.startOfDay(for: anniversary), to: calendar.startOfDay(for: date)).year ?? 0
            guard years >= 1 else { return false }
        }
        let original = calendar.dateComponents([.month, .day], from: anniversary)
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        if original.month == today.month && original.day == today.day { return true }
        return original.month == 2 && original.day == 29 && today.month == 2 && today.day == 28
            && calendar.range(of: .day, in: .month, for: date)?.count == 28
    }
}

extension Pet {
    /// Derives the stage on demand so it advances with age and never needs manual updates.
    func lifeStage(on date: Date = .now) -> PetLifeStage? {
        PetLifeStage.estimate(birthdate: birthdate, species: species, on: date)
    }

    /// Uses the real birthday when known, otherwise the day this pet joined the salon.
    /// The fallback is only for celebrating; it never participates in age calculations.
    var annualCelebrationDate: Date { birthdate ?? createdAt }

    struct CelebrationStatus: Equatable, Sendable {
        let isCelebrating: Bool
        let isHonorary: Bool
    }

    /// True on the pet's birthday, or on the annual anniversary of joining the salon (after at least 1 year).
    func celebrationStatus(on date: Date = .now, calendar: Calendar = .current) -> CelebrationStatus {
        if let birthdate {
            return CelebrationStatus(
                isCelebrating: PetMilestones.isAnniversary(birthdate, on: date, calendar: calendar, requiresAtLeastOneYear: false),
                isHonorary: false
            )
        } else {
            return CelebrationStatus(
                isCelebrating: PetMilestones.isAnniversary(createdAt, on: date, calendar: calendar, requiresAtLeastOneYear: true),
                isHonorary: true
            )
        }
    }
}
