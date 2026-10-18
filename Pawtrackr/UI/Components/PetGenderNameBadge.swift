//
//  PetGenderNameBadge.swift
//  Pawtrackr
//

import SwiftUI

struct PetGenderNameBadge: View {
    let pet: Pet
    var showsDescriptor = false
    var maxNameWidth: CGFloat = 170

    var body: some View {
        HStack(spacing: 6) {
            SpeciesAndGenderIcons.genderDot(for: pet.gender, size: 9, isDecorative: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(pet.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxNameWidth, alignment: .leading)
                if showsDescriptor {
                    Text(pet.shortDescriptor)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .font(.caption.weight(showsDescriptor ? .semibold : .regular))
        .foregroundStyle(.primary)
        .padding(.vertical, showsDescriptor ? 5 : 3)
        .padding(.horizontal, 8)
        .background(DS.ColorToken.gender(pet.gender).opacity(0.12), in: Capsule())
        .overlay(
            Capsule().stroke(DS.ColorToken.gender(pet.gender).opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pet.name), \(pet.gender.displayName)")
    }
}
