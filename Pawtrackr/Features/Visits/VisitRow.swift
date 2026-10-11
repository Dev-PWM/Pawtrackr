//
//  VisitRow.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-09-03.
//

import SwiftUI

struct VisitRow: View {
    let visit: Visit
    var heroNamespace: Namespace.ID? = nil

    var body: some View {
        // FIX: Use the correct Card initializer.
        Card(
            elevation: .regular,
            accent: .leading(.color(DS.ColorToken.gender(visit.pet?.gender)), thickness: 4)
        ) {
            HStack(alignment: .top, spacing: 12) {
                VStack {
                    heroAvatar
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    header
                    services
                    footer
                    VisitLoyaltyReceipt(visit: visit)
                }
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        let avatar = AvatarView(
            .pet(
                species: visit.pet?.species,
                gender: visit.pet?.gender,
                name: visit.pet?.name ?? "Unknown",
                imageData: visit.pet?.photoData,
                thumbnailData: visit.pet?.thumbnailData
            ),
            size: .md
        )

        if let heroNamespace {
            avatar.matchedGeometryEffect(id: heroID, in: heroNamespace)
        } else {
            avatar
        }
    }

    private var heroID: String {
        "visit-avatar-\(visit.uuid.uuidString)"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(visit.pet?.owner?.fullName ?? "Unknown Owner")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(visit.pet?.name ?? "Unknown")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Text(visit.totalCurrencyString)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(String(format: AppLocalization.localized("a11y.amount_fmt", value: "Amount %@"), visit.totalCurrencyString))
        }
    }

    @ViewBuilder
    private var services: some View {
        if !(visit.items ?? []).isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(visit.items ?? []) { item in
                    // FIX: Replaced 'Pill' with the correct 'Chip' component.
                    Chip(item.displayName, style: .tinted, size: .xs)
                }
            }
        }
    }
    
    private var footer: some View {
        HStack {
            Label(visit.durationString, systemImage: "clock")
            if let note = visit.note, !note.trimmed.isEmpty {
                Label(AppLocalization.localized("visit.note", value: "Note"), systemImage: "note.text")
            }
            if visit.beforePhotoData != nil
                || visit.afterPhotoData != nil
                || visit.beforeThumbnailData != nil
                || visit.afterThumbnailData != nil {
                Label(NSLocalizedString("visit.photos", comment: ""), systemImage: "photo.on.rectangle")
            }
            Spacer()
            // import, telling groomers visits were backed up when they weren't.
            // Backup status lives in the toolbar icon and Settings.

            if let paymentMethod = visit.payment?.method {
                Label(paymentMethod.displayName, systemImage: paymentMethod.systemImage)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}
