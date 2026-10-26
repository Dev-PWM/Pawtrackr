//
//  PetGender.swift
//  Pawtrackr
//
//  Simple gender enum used by Pet and UI components.
//  Blue for male, pink for female in UI (color decisions live in views).
//
//  Created by mac on 8/14/25.
//  Updated by mac on 8/17/25.
//

import Foundation

public enum PetGender: String, CaseIterable, Codable, Identifiable, Sendable {
    case male
    case female

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .male:
            return AppLocalization.localized("gender.male", value: "Male")
        case .female:
            return AppLocalization.localized("gender.female", value: "Female")
        }
    }

    /// Optional SF Symbol for small badges (actual color chosen by the View layer)
    public var symbolName: String { self == .male ? "m.circle.fill" : "f.circle.fill" }
}
