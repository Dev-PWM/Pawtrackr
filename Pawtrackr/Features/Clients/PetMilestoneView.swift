import SwiftUI

/// Read-only age and celebration cues, refreshed across local midnight without model writes.
struct PetMilestoneView: View {
    let pet: Pet

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let celebration = pet.celebration(on: context.date)
            let stage = pet.lifeStage(on: context.date)

            if celebration != nil || stage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let stage {
                        Label(String(format: AppLocalization.localized("pet.stage.estimated", value: "%@ · estimated"), stage.title(for: pet.species)), systemImage: stage == .senior ? "cross.case.fill" : "pawprint.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(stage == .senior ? Color.orange : Color.secondary)
                        if stage == .senior {
                            Text(AppLocalization.localized("pet.stage.senior_care", value: "Senior · Check comfort and handling needs with the owner."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let celebration {
                        PetCelebrationBanner(pet: pet, celebration: celebration)
                            .id(celebration)
                    }
                }
            }
        }
    }
}

/// Localized, factual copy shared by the banner and accessibility presentation.
enum PetCelebrationCopy {
    static func title(_ celebration: PetCelebration, name: String, gender: PetGender?) -> String {
        switch celebration {
        case .birthday:
            let key: String
            let fallback: String
            switch gender {
            case .male: (key, fallback) = ("pet.celebration.boy", "Birthday boy, %@!")
            case .female: (key, fallback) = ("pet.celebration.girl", "Birthday girl, %@!")
            case nil: (key, fallback) = ("pet.celebration.birthday", "Happy birthday, %@!")
            }
            return String(format: AppLocalization.localized(key, value: fallback), name)
        case let .salonAnniversary(years):
            return String(format: AppLocalization.localized(
                years == 1 ? "pet.celebration.one_year" : "pet.celebration.years",
                value: years == 1 ? "%d year with us!" : "%d years with us!"), years)
        }
    }

    static func detail(_ celebration: PetCelebration, clientName: String?) -> String {
        switch celebration {
        case let .birthday(age):
            if age == 0 { return AppLocalization.localized("pet.celebration.born", value: "Welcome to the world!") }
            return String(format: AppLocalization.localized(
                "pet.celebration.turning", value: "Turning %d today. Let’s celebrate!"), age)
        case .salonAnniversary:
            guard let clientName, !clientName.isEmpty else {
                return AppLocalization.localized(
                    "pet.celebration.family", value: "Celebrating your family’s time at the salon.")
            }
            return String(format: AppLocalization.localized(
                "pet.celebration.thanks", value: "Thank you, %@, for being part of our salon family."), clientName)
        }
    }
}

/// A replayable, finite burst; the message stays readable when motion is disabled.
private struct PetCelebrationBanner: View {
    let pet: Pet
    let celebration: PetCelebration
    @State private var replayID = 0

    private var isBirthday: Bool {
        if case .birthday = celebration { return true }
        return false
    }

    private var accent: Color {
        guard isBirthday else { return .orange }
        switch PetGender(rawValue: pet.genderRaw) {
        case .male: return DS.ColorToken.info
        case .female: return .pink
        case nil: return .purple
        }
    }
    private var title: String {
        PetCelebrationCopy.title(celebration, name: pet.name, gender: PetGender(rawValue: pet.genderRaw))
    }
    private var detail: String { PetCelebrationCopy.detail(celebration, clientName: pet.owner?.fullName) }

    var body: some View {
        MotionAwareView { allowsMotion in
            Button { replayID += 1 } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: isBirthday ? "birthday.cake.fill" : "party.popper.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.subheadline.weight(.bold)).foregroundStyle(DS.ColorToken.textPrimary)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "sparkles").foregroundStyle(accent).accessibilityHidden(true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.2)))
                .overlay {
                    if allowsMotion {
                        CelebrationConfetti(replayID: replayID, isBirthday: isBirthday)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
            .pressScaleStyle()
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title + " " + detail)
            .accessibilityHint(allowsMotion
                ? AppLocalization.localized("pet.celebration.replay", value: "Tap to celebrate again.") : "")
            .accessibilityIdentifier("petProfile.birthdayBanner")
        }
    }
}

/// Clock-driven particles stop after two seconds, and disappear immediately when motion is disallowed.
private struct CelebrationConfetti: View {
    let replayID: Int
    let isBirthday: Bool
    @State private var startedAt = Date.now
    @State private var isPlaying = true

    var body: some View {
        ZStack {
            Color.clear
            if isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        let progress = min(1, max(0, timeline.date.timeIntervalSince(startedAt) / 2))
                        let colors: [Color] = isBirthday
                            ? [.pink, .cyan, .yellow, .mint] : [.orange, .indigo, .yellow, .mint]
                        for index in 0..<24 {
                            let seed = Double(index) / 24
                            let spread = sin(Double(index * 47))
                            let horizontal = size.width * seed + spread * 32 * progress
                            let vertical = -12 + (size.height + 24) * progress + sin(seed * .pi) * 18
                            var particle = context
                            particle.opacity = (1 - progress) * 0.85
                            particle.translateBy(x: horizontal, y: vertical)
                            particle.rotate(by: .degrees(Double(index * 37) + progress * 220))
                            particle.fill(Path(roundedRect: CGRect(x: -2.5, y: -4, width: 5, height: 8),
                                               cornerRadius: 1.5), with: .color(colors[index % colors.count]))
                        }
                    }
                }
            }
        }
        .clipped()
        .task(id: replayID) {
            startedAt = .now
            isPlaying = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            isPlaying = false
        }
    }
}
