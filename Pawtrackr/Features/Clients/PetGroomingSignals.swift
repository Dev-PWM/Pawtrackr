import SwiftUI

/// Keeps visit-recorded handling cues visible without adding care fields to the profile editor.
struct PetGroomingSignals: View {
    let pet: Pet

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(BehaviorTagIcons.selectedTags(from: pet.behaviorTags).filter { !Pet.isAggressiveTag($0) && Pet.behaviorTagKind(for: $0) != .specialNeeds }, id: \.self) { tag in
                let display = BehaviorTagIcons.display(for: tag)
                Text((display.emoji.map { "\($0) " } ?? "") + display.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(.primary)
                    .background(tint(for: tag).opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(tint(for: tag).opacity(0.5), lineWidth: 1))
                    .accessibilityLabel(display.label)
                    .accessibilityIdentifier("pet.behavior.\(Pet.behaviorTagKind(for: tag)?.rawValue ?? tag)")
            }
            if let health = pet.health, !health.trimmed.isEmpty {
                Label(health, systemImage: "cross.case.fill")
                    .font(.caption).foregroundStyle(DS.ColorToken.danger)
            }
        }
    }

    /// Uses both labels and color so handling cues remain accessible without color perception.
    private func tint(for tag: String) -> Color {
        BehaviorTagIcons.tint(for: Pet.behaviorTagKind(for: tag))
    }
}

/// Persistent priority-care notice; it is not a temperament or a clearance counter.
struct SpecialNeedsPetBadge: View {
    var body: some View {
        Label(AppLocalization.localized("pet.safety.special_needs_badge", value: "Special needs — priority care"), systemImage: "cross.case.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(BehaviorTagIcons.tint(for: .specialNeeds), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("pet.specialNeeds.priorityBadge")
    }
}
