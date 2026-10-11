//
//  VisitTimelineRow.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-09-03.
//

import SwiftUI

struct VisitTimelineRow: View {
    let visit: Visit
    var heroNamespace: Namespace.ID? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                topRow
                timingRow
                services
                footer
                VisitLoyaltyReceipt(visit: visit)
            }
        }
    }

    private var topRow: some View {
        HStack(alignment: .top) {
            HStack(spacing: 10) {
                heroAvatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(visit.pet?.name ?? "Unknown").font(.subheadline.weight(.semibold))
                    Text("\(visit.pet?.shortDescriptor ?? "") • \(visit.pet?.owner?.fullName ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if visit.isPaid {
                Text(NSLocalizedString("visit.paid", comment: ""))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green))
                    .foregroundStyle(.white)
            } else if visit.isActive {
                Text(NSLocalizedString("visit.processing", comment: ""))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange))
                    .foregroundStyle(.white)
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

    private var timingRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("visit.check_in_time", comment: "")).font(.caption).foregroundStyle(.secondary)
                Text(Formatters.timeOnly.string(from: visit.startedAt)).font(.subheadline.weight(.medium))
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("visit.check_out_time", comment: "")).font(.caption).foregroundStyle(.secondary)
                if let end = visit.endedAt {
                    Text(Formatters.timeOnly.string(from: end)).font(.subheadline.weight(.medium))
                } else {
                    Text(NSLocalizedString("visit.in_progress", comment: "")).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
    }
    
    @ViewBuilder
    private var services: some View {
        if !(visit.items ?? []).isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(visit.items ?? []) { item in
                    Chip(item.displayName, style: .tinted, size: .sm)
                }
            }
        }
    }
    
    private var footer: some View {
        HStack {
            HStack(spacing: 14) {
                Label(visit.durationString, systemImage: "clock")
                Label(visit.totalCurrencyString, systemImage: "dollarsign.circle")
                if let paymentMethod = visit.payment?.method {
                    Label(paymentMethod.displayName, systemImage: paymentMethod.systemImage)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}
