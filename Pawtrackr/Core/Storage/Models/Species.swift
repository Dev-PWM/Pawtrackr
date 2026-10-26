//
//  Species.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//

import Foundation

// FIX: Added 'public' to match the access level of AvatarView.
public enum Species: String, CaseIterable, Codable, Identifiable, Sendable {
    case dog
    case cat

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dog:
            return AppLocalization.localized("species.dog", value: "Dog")
        case .cat:
            return AppLocalization.localized("species.cat", value: "Cat")
        }
    }

    public var iconName: String {
        switch self {
        case .dog: return "pawprint.fill"
        case .cat: return "pawprint"
        }
    }
}
