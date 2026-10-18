//
//  AvatarView.swift
//  Pawtrackr
//
//  Created by mac on 9/2/25.
//

import SwiftUI

/// A thin wrapper around `IconCircle` that standardizes avatar usage across the app
/// for both Clients and Pets. Prefer this over using `IconCircle` directly in screens.
public struct AvatarView: View {
    // MARK: Public API

    public enum Kind: Equatable {
        case client(name: String, imageData: Data? = nil, thumbnailData: Data? = nil, imageURL: URL? = nil)
        case pet(species: Species?, gender: PetGender?, name: String? = nil, imageData: Data? = nil, thumbnailData: Data? = nil, imageURL: URL? = nil)
        case systemImage(_ name: String)
        case initials(_ text: String)
        case imageData(_ data: Data)
        case imageURL(_ url: URL)
    }

    public enum Size: Equatable {
        case xs, sm, md, lg
        case custom(CGFloat)

        var token: IconCircle.SizeToken {
            switch self {
            case .xs: return .xs
            case .sm: return .sm
            case .md: return .md
            case .lg: return .lg
            case .custom(let v): return .custom(v)
            }
        }
    }

    public var kind: Kind
    public var size: Size
    /// Optional ring around the avatar (0 = no ring).
    public var ringWidth: CGFloat
    /// Optional small badge in the bottom‑trailing corner.
    public var badgeSystemImage: String?
    public var badgeColor: Color?
    public var accessibilityLabel: String?

    // MARK: Init

    /// Explicit initials for list presentations whose name order can change.
    public var initialsOverride: String?

    public init(_ kind: Kind,
                size: Size = .md,
                ringWidth: CGFloat = 0,
                badgeSystemImage: String? = nil,
                badgeColor: Color? = nil,
                accessibilityLabel: String? = nil,
                initialsOverride: String? = nil) {
        self.kind = kind
        self.size = size
        self.ringWidth = ringWidth
        self.badgeSystemImage = badgeSystemImage
        self.badgeColor = badgeColor
        self.accessibilityLabel = accessibilityLabel
        self.initialsOverride = initialsOverride
    }

    /// Convenience for clients (owners).
    public init(clientName: String,
                imageData: Data? = nil,
                thumbnailData: Data? = nil,
                imageURL: URL? = nil,
                size: Size = .md,
                ringWidth: CGFloat = 0,
                badgeSystemImage: String? = nil,
                badgeColor: Color? = nil,
                accessibilityLabel: String? = nil) {
        self.init(.client(name: clientName, imageData: imageData, thumbnailData: thumbnailData, imageURL: imageURL),
                  size: size,
                  ringWidth: ringWidth,
                  badgeSystemImage: badgeSystemImage,
                  badgeColor: badgeColor,
                  accessibilityLabel: accessibilityLabel)
    }

    /// Convenience for pets.
    public init(petName: String? = nil,
                species: Species?,
                gender: PetGender?,
                imageData: Data? = nil,
                thumbnailData: Data? = nil,
                imageURL: URL? = nil,
                size: Size = .md,
                ringWidth: CGFloat = 0,
                badgeSystemImage: String? = nil,
                badgeColor: Color? = nil,
                accessibilityLabel: String? = nil) {
        self.init(.pet(species: species, gender: gender, name: petName, imageData: imageData, thumbnailData: thumbnailData, imageURL: imageURL),
                  size: size,
                  ringWidth: ringWidth,
                  badgeSystemImage: badgeSystemImage,
                  badgeColor: badgeColor,
                  accessibilityLabel: accessibilityLabel)
    }

    // MARK: Body

    public var body: some View {
        Group {
            switch kind {
            case .client(let name, let data, let thumb, let url):
                IconCircle(
                    systemImage: "person.crop.circle.fill",
                    initials: name,
                    initialsOverride: initialsOverride,
                    imageData: data,
                    thumbnailData: thumb,
                    imageURL: url,
                    size: size.token,
                    style: .solid(bg: DS.ColorToken.primary.opacity(0.12), fg: DS.ColorToken.primary),
                    lineWidth: ringWidth,
                    badgeSystemImage: badgeSystemImage,
                    badgeColor: badgeColor,
                    accessibilityLabel: accessibilityLabel ?? name
                )

            case .pet(let species, let gender, let name, let data, let thumb, let url):
                IconCircle(
                    systemImage: systemImageForPet(species: species),
                    initials: name,
                    imageData: data,
                    thumbnailData: thumb,
                    imageURL: url,
                    size: size.token,
                    style: .auto(species: species, gender: gender),
                    lineWidth: ringWidth,
                    badgeSystemImage: badgeSystemImage,
                    badgeColor: badgeColor,
                    accessibilityLabel: accessibilityLabel ?? (name ?? species?.displayName ?? "Pet Avatar")
                )

            case .systemImage(let system):
                IconCircle(
                    systemImage: system,
                    size: size.token,
                    style: .tinted(Color.primary.opacity(0.10)),
                    lineWidth: ringWidth,
                    badgeSystemImage: badgeSystemImage,
                    badgeColor: badgeColor,
                    accessibilityLabel: accessibilityLabel
                )

            case .initials(let text):
                IconCircle(
                    initials: text,
                    size: size.token,
                    style: .tinted(Color.primary.opacity(0.10)),
                    lineWidth: ringWidth,
                    badgeSystemImage: badgeSystemImage,
                    badgeColor: badgeColor,
                    accessibilityLabel: accessibilityLabel ?? text
                )

            case .imageData(let data):
                IconCircle(
                    imageData: data,
                    size: size.token,
                    style: .tinted(Color.primary.opacity(0.10)),
                    lineWidth: ringWidth,
                    badgeSystemImage: badgeSystemImage,
                    badgeColor: badgeColor,
                    accessibilityLabel: accessibilityLabel
                )

            case .imageURL(let url):
                IconCircle(
                    imageURL: url,
                    size: size.token,
                    style: .tinted(Color.primary.opacity(0.10)),
                    lineWidth: ringWidth,
                    badgeSystemImage: badgeSystemImage,
                    badgeColor: badgeColor,
                    accessibilityLabel: accessibilityLabel
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: - Helpers

    private var accessibilityLabelText: String {
        switch kind {
        case .client(let name, _, _, _):
            return name
        case .pet(_, _, let name, _, _, _):
            return name ?? "Pet"
        case .systemImage:
            return accessibilityLabel ?? "Avatar"
        case .initials(let text):
            return text
        case .imageData, .imageURL:
            return accessibilityLabel ?? "Avatar"
        }
    }

    private func systemImageForPet(species: Species?) -> String {
        switch species {
        case .some(.cat): return "pawprint"
        case .some(.dog): return "pawprint.fill"
        default: return "pawprint.fill"
        }
    }
}

// MARK: - Previews
#if DEBUG
#Preview("AvatarView – Clients & Pets") {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            AvatarView(.client(name: "Alex Carter"), size: .sm)
            AvatarView(.client(name: "Riley Q", imageData: nil), size: .md, ringWidth: 2)
            AvatarView(.client(name: "Pat Lee"), size: .lg, badgeSystemImage: "phone.fill")
        }
        HStack(spacing: 16) {
            AvatarView(.pet(species: .dog, gender: .male, name: "Max"), size: .sm)
            AvatarView(.pet(species: .cat, gender: .female, name: "Luna"), size: .md, ringWidth: 2)
            AvatarView(.pet(species: .dog, gender: .male, name: "Spike"), size: .lg, badgeSystemImage: "clock.fill")
        }
        HStack(spacing: 16) {
            AvatarView(.systemImage("pawprint.circle.fill"), size: .sm)
            AvatarView(.initials("AC"), size: .md)
        }
    }
    .padding()
    .background(DS.ColorToken.background)
}
#endif
