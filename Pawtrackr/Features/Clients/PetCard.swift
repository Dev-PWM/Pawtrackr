//
//  PetCard.swift
//  Pawtrackr
//
//  Created by mac on 8/28/25.
//

import SwiftUI
import SwiftData

/// Compact, tappable card that shows a pet, its current session state, and quick actions.
struct PetCard: View {
    // MARK: - Inputs
    let pet: Pet
    /// If a visit is in progress for this pet, pass it here (nil when idle)
    let activeVisit: Visit?
    let onViewDetails: () -> Void
    let onCheckIn: () -> Void
    let onCheckOut: () -> Void
    var namespace: Namespace.ID? = nil

    // MARK: - State / Environment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var visitTimer = VisitTimer()
    @State private var pulse: Bool = false

    // MARK: - Derived
    private var isActive: Bool { activeVisit?.endedAt == nil && activeVisit != nil }

    private var elapsedString: String {
        guard let v = activeVisit else { return "" }
        if v.endedAt != nil { return v.durationString }
        return visitTimer.formattedElapsed
    }

    // MARK: - View
    var body: some View {
        Card(elevation: .regular, accent: .leading(.color(DS.ColorToken.gender(pet.gender)), thickness: 4)) {
            cardContent
        }
        .petBehaviorAura(pet: pet)
        .scaleEffect(isActive ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if isActive { visitTimer.sceneBecameActive() }
            case .inactive, .background:
                // Pause the tick subscription so we don't accumulate elapsed
                // time or burn battery while the app is not foregrounded.
                visitTimer.sceneWillResignActive()
            @unknown default:
                break
            }
        }
        .onAppear { syncTimer() }
        .onChange(of: activeVisit?.startedAt) { _, _ in syncTimer() }
        .onChange(of: activeVisit?.endedAt) { _, _ in syncTimer() }
        .onChange(of: isActive) { _, newValue in pulse = newValue }
    }

    // MARK: - Subviews
    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            let avatar = AvatarView(.pet(species: pet.species, gender: pet.gender, name: pet.name, imageData: pet.photoData, thumbnailData: pet.thumbnailData), size: .md)

            if let namespace {
                avatar.matchedGeometryEffect(id: "pet-avatar-\(pet.id)", in: namespace)
            } else {
                avatar
            }

            mainContent
            Spacer(minLength: 0)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            if pet.hasSpecialNeeds { SpecialNeedsPetBadge() }
            breedLine
            PetMilestoneView(pet: pet)
            behaviorTags
            healthLine
            sessionLine
            actionRow
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 8) {
                Text(pet.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isActive { inProgressBadge }
            }
            Spacer()
            Button(action: onViewDetails) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(DS.ColorToken.surface, in: Circle())
                    .accessibilityLabel(AppLocalization.localized("a11y.view_details", value: "View details"))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var breedLine: some View {
        if let breed = pet.breed, !breed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(breed)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var behaviorTags: some View {
        if !pet.behaviorTags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Pet.cleanedBehaviorTags(pet.behaviorTags).filter { Pet.behaviorTagKind(for: $0) != .specialNeeds }, id: \.self) { tag in
                    let isDanger = Pet.isAggressiveTag(tag)
                    let disp = BehaviorTagIcons.display(for: tag)
                    let kind = Pet.behaviorTagKind(for: tag)

                    if isDanger {
                        let status = pet.aggressionClearanceStatus
                        let labelText = status.isProbationary
                            ? "⚠️ \(disp.label) (\(status.calmStreak)/3)"
                            : "⚠️ \(disp.label)"
                        Chip(labelText, style: .filled, size: .xs)
                            .foregroundStyle(.white)
                            .background(DS.ColorToken.danger, in: Capsule())
                            .accessibilityLabel(
                                status.isProbationary
                                    ? String(format: NSLocalizedString("pet.safety.probation_a11y_fmt", value: "Warning: this pet is marked aggressive, %d of 3 visits without aggression to clear.", comment: ""), status.calmStreak)
                                    : NSLocalizedString("pet.safety.aggressive_a11y", value: "Warning: this pet is marked aggressive. Handle with care.", comment: "")
                            )
                    } else {
                        let tint = BehaviorTagIcons.tint(for: kind)
                        Text((disp.emoji.map { "\($0) " } ?? "") + disp.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(.primary)
                            .background(tint.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 1))
                            .accessibilityLabel(disp.label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var healthLine: some View {
        if let health = pet.health?.trimmingCharacters(in: .whitespacesAndNewlines), !health.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "cross.case.fill").foregroundStyle(.red.opacity(0.8))
                Text(health).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sessionLine: some View {
        if isActive {
            liveTimer
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let status = pet.nextVisitStatus {
                    HStack(spacing: 6) {
                        Image(systemName: pet.isOverdue ? "exclamationmark.circle.fill" : "calendar")
                            .foregroundStyle(pet.isOverdue ? .red : .blue)
                        Text(status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(pet.isOverdue ? .red : .blue)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background((pet.isOverdue ? Color.red : Color.blue).opacity(0.1), in: Capsule())
                }

                if let last = (pet.visits ?? []).filter({ $0.isCompleted }).sorted(by: { $0.sortKeyDate > $1.sortKeyDate }).first {
                    Text(String(format: NSLocalizedString("pet.last_visit_fmt", comment: ""), last.sortKeyDate.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var liveTimer: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.ColorToken.success)
                VStack(spacing: 2) {
                    Text(elapsedString)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(DS.ColorToken.success)
                    Text(NSLocalizedString("status.in_session", comment: ""))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.ColorToken.success)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [
                        DS.ColorToken.success.opacity(0.18),
                        DS.ColorToken.success.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.ColorToken.success.opacity(0.25), lineWidth: 1)
            )
            .scaleEffect(pulse ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .onDisappear { pulse = false }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(visitTimer.accessibilityElapsedLabel)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if isActive {
                Button(action: onCheckOut) {
                    Label(NSLocalizedString("pet.check_out", comment: ""), systemImage: "creditcard.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button(action: onCheckIn) {
                    Label(NSLocalizedString("pet.check_in", comment: ""), systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            Button(action: onViewDetails) {
                Label(AppLocalization.localized("pet.view_details", value: "View Details"), systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
        }
        .font(.subheadline)
        .padding(.top, 2)
    }

    private var inProgressBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(DS.ColorToken.success).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(NSLocalizedString("status.in_session", comment: "")).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.ColorToken.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(DS.ColorToken.success)
        .accessibilityLabel(AppLocalization.localized("a11y.in_session", value: "In session"))
    }

    private var accessibilitySummary: String {
        var parts: [String] = [pet.name]
        parts.append(genderLabel)
        parts.append(speciesLabel)
        if isActive { parts.append("In session \(visitTimer.accessibilityElapsedLabel)") }
        return parts.joined(separator: ", ")
    }

    private var genderLabel: String { pet.gender == .male ? "Male" : "Female" }

    private var speciesLabel: String { pet.species.displayName }

    // MARK: - Timer sync
    private func syncTimer() {
        guard let v = activeVisit else { visitTimer.reset(); return }
        visitTimer.load(startedAt: v.startedAt, endedAt: v.endedAt)
    }
}

// MARK: - Preview
#if DEBUG
struct PetCard_Previews: PreviewProvider {
    static var previews: some View {
        let owner = Client(firstName: "Sarah", lastName: "Johnson", phone: "+15551234567")
        let pet1 = Pet(name: "Max", species: .dog, gender: .male)
        let pet2 = Pet(name: "Bella", species: .cat, gender: .female)
        owner.pets = (owner.pets ?? []) + [pet1, pet2]

        let active = Visit(pet: pet1)

        return VStack(spacing: 16) {
            PetCard(pet: pet1, activeVisit: active, onViewDetails: {}, onCheckIn: {}, onCheckOut: {})
            PetCard(pet: pet2, activeVisit: nil, onViewDetails: {}, onCheckIn: {}, onCheckOut: {})
        }
        .padding()
        .modelContainer(for: [Client.self, Pet.self, Visit.self, VisitItem.self, Payment.self], inMemory: true)
        .previewDisplayName("Pet Card Variants")
    }
}
#endif
