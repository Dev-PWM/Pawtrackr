//
//  ClientRow.swift
//  Pawtrackr
//
//  Reusable row for Clients list.
//  Shows: owner name, phone, optional "In Progress" badge when any pet is checked in,
//  and stacked pet avatars (dog/cat, blue=male, pink=female). Tappable via onTap.
//
//  Created by mac on 8/14/25.
//  Updated by mac on 8/17/25.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ClientRow: View {
    let client: Client
    var inProgress: Bool
    /// True on a client list sorted by last name, so the name reads the way
    /// the list is ordered ("Cullen Alien"). Everywhere else (headers,
    /// receipts, messages, Recent Clients) stays first-name-first.
    var displaysLastNameFirst: Bool
    var onTap: (() -> Void)?

    init(
        client: Client,
        inProgress: Bool? = nil,
        displaysLastNameFirst: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.client = client
        self.displaysLastNameFirst = displaysLastNameFirst
        // If explicit flag not provided, infer from any active visit among this client's pets
        if let inProgress = inProgress {
            self.inProgress = inProgress
        } else {
            self.inProgress = ClientRow.hasActiveVisit(client: client)
        }
        self.onTap = onTap
    }

    var body: some View {
        let primaryPet = (client.pets ?? []).sorted(by: { $0.name < $1.name }).first

        HStack(alignment: .center, spacing: 16) {
            if let pet = primaryPet {
                IconCircle(size: .md, style: .auto(species: pet.species, gender: pet.gender), lineWidth: 1)

                PetGenderNameBadge(pet: pet, maxNameWidth: 180)
            } else {
                // Fallback if no pets exist for the client
                Text(client.displayName(lastNameFirst: displaysLastNameFirst))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityAddTraits(.isButton)
    }

    // Naive inference: any pet with a Visit that has no endedAt means "in progress"
    private static func hasActiveVisit(client: Client) -> Bool {
        for pet in client.pets ?? [] {
            if (pet.visits ?? []).contains(where: { $0.endedAt == nil }) { return true }
        }
        return false
    }
}

// MARK: - Preview

struct ClientRow_Previews: PreviewProvider {
    static var previews: some View {
        // Minimal fakes for preview only
        let owner = Client(firstName: "Sarah", lastName: "Johnson", phone: "5551234567")
        let max = Pet(name: "Max", species: .dog)
        max.gender = .male
        let bella = Pet(name: "Bella", species: .dog)
        bella.gender = .female
        let kitty = Pet(name: "Mimi", species: .cat)
        kitty.gender = .female
        owner.pets = [max, bella, kitty]

        return VStack(spacing: 12) {
            ClientRow(client: owner, inProgress: true)
            ClientRow(client: owner, inProgress: false)
        }
        .padding()
#if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
#else
        .background(Color(.systemGroupedBackground))
#endif
        .previewLayout(.sizeThatFits)
    }
}
