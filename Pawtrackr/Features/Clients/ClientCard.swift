

//
//  ClientCard.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-09-03.
//

import SwiftUI

struct ClientCard: View {
    let client: Client
    var namespace: Namespace.ID? = nil
    /// When set, the list (which groups clients via a fresh store query) is the
    /// source of truth for the "In Session" state. Reading `client.hasActiveVisit`
    /// off the in-memory relationship goes stale after a cross-context checkout,
    /// so prefer the caller's query-derived value when available.
    var isInProgressOverride: Bool? = nil
    var displaysLastNameFirst: Bool = false
    /// Spell out what the record lacks (the Missing Info filter).
    var showsMissingDetails: Bool = false

    private var visualState: VisualState {
        VisualState(client: client, isInProgressOverride: isInProgressOverride)
    }
    private var isInProgress: Bool { visualState.isInProgress }
    private var needsAttention: Bool { visualState.needsAttention }
    private var missingInfo: [ClientMissingInfo] { ClientMissingInfo.items(for: client) }
    private var hasMissingInfo: Bool { !missingInfo.isEmpty }
    private var displayName: String { client.displayName(lastNameFirst: displaysLastNameFirst) }

    private var ownerAvatar: some View {
        AvatarView(
            .client(name: client.fullName),
            size: .sm,
            accessibilityLabel: client.fullName,
            initialsOverride: IconCircle.makeClientInitials(
                firstName: client.firstName,
                lastName: client.lastName,
                lastNameFirst: displaysLastNameFirst
            )
        )
        .accessibilityIdentifier("clients.avatar.\(client.fullName)")
    }
    private var sortedPets: [Pet] {
        (client.pets ?? []).filter { $0.archivedAt == nil }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    

    var body: some View {
        let state = visualState
        let accentColor: Color? = switch state.accentKind {
        case .safety:
            DS.ColorToken.danger
        case .priorityCare:
            BehaviorTagIcons.tint(for: .specialNeeds)
        case .inProgress:
            DS.ColorToken.success
        case .attention:
            Color.orange
        case .none:
            nil
        }

        Card(elevation: .regular, accent: accentColor != nil ? .leading(.color(accentColor!), thickness: 4) : nil) {
            VStack(alignment: .leading, spacing: 10) {
                if state.showsAggressiveWarning { aggressiveBanner }
                if state.showsSpecialNeedsWarning { SpecialNeedsPetBadge() }
                header
                if showsMissingDetails, let summary = ClientMissingInfo.summary(missingInfo) {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                phoneInfo
                petsInfo
            }
        }
        .id(state.identityKey)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let namespace {
                ownerAvatar
                    .matchedGeometryEffect(id: "avatar-\(client.id)", in: namespace)
            } else {
                ownerAvatar
            }
            
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .id("name-\(client.id)")
            }
            
            Spacer()
            // Aggressive state is shown by the prominent banner above; keep the
            // header chips for status only to avoid a redundant double-warning.
            if isInProgress {
                Chip.success("In Session")
            } else if needsAttention {
                Chip.warning(NSLocalizedString("clients.needs_attention", value: "Needs Attention", comment: ""))
            } else if hasMissingInfo {
                Chip.info(NSLocalizedString("clients.filter.missing_info", value: "Missing Info", comment: ""))
            }
        }
    }

    /// Loud, full-width safety warning shown at the top of the card whenever any
    /// of the client's pets is flagged aggressive. Staff see the danger before
    /// they tap into the client. Mirrors the detail-view safety banner.
    private var aggressiveBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Text(NSLocalizedString("pet.safety.aggressive_badge", value: "Aggressive — handle with care", comment: ""))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.danger, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(NSLocalizedString("pet.safety.aggressive_a11y", value: "Warning: this pet is marked aggressive. Handle with care.", comment: ""))
    }

    @ViewBuilder
    private var phoneInfo: some View {
        if let phone = client.phone, !phone.isEmpty {
            Label(PhoneUtils.display(phone) ?? phone, systemImage: "phone.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
    
    private var petsInfo: some View {
        let pets = sortedPets

        return HStack(alignment: .top, spacing: 0) {
            if pets.isEmpty {
                Text(NSLocalizedString("clients.no_pets", value: "No pets", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(pets) { pet in
                        PetGenderNameBadge(pet: pet, maxNameWidth: 150)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)
            }

            Spacer()
        }
    }


}
extension ClientCard {
    struct VisualState: Equatable {
        enum AccentKind: String, Equatable {
            case safety
            case priorityCare
            case inProgress
            case attention
        }

        let showsAggressiveWarning: Bool
        let showsSpecialNeedsWarning: Bool
        let isInProgress: Bool
        let needsAttention: Bool
        let accentKind: AccentKind?
        let identityKey: String

        init(client: Client, isInProgressOverride: Bool?) {
            let pets = (client.pets ?? []).filter { $0.archivedAt == nil }
            showsAggressiveWarning = pets.contains { $0.isAggressive }
            showsSpecialNeedsWarning = pets.contains { $0.hasSpecialNeeds }
            isInProgress = isInProgressOverride ?? client.hasActiveVisit
            needsAttention = pets.contains { $0.needsAttention }

            if showsAggressiveWarning {
                accentKind = .safety
            } else if showsSpecialNeedsWarning {
                accentKind = .priorityCare
            } else if isInProgress {
                accentKind = .inProgress
            } else if needsAttention {
                accentKind = .attention
            } else {
                accentKind = nil
            }

            let behaviorSignature = pets
                .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
                .map { pet in
                    let tags = pet.behaviorTags
                        .map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
                        .joined(separator: ",")
                    return "\(pet.uuid.uuidString):\(tags)"
                }
                .joined(separator: "|")

            identityKey = [
                client.uuid.uuidString,
                "safety:\(showsAggressiveWarning)",
                "accent:\(accentKind?.rawValue ?? "none")",
                "behaviors:\(behaviorSignature)"
            ].joined(separator: "|")
        }
    }
}
