//
//  BehaviorTagIcons.swift
//  Pawtrackr
//
//  Utility to map pet behavior tags to a short label with an emoji for display.
//

import Foundation
import SwiftUI

enum BehaviorTagIcons {
    /// Only explicit, supported behavior choices belong in behavior UI.
    /// Legacy demo labels are preserved in storage but never shown as choices.
    static func selectedTags(from tags: [String]) -> [String] {
        Pet.cleanedBehaviorTags(tags).filter { Pet.behaviorTagKind(for: $0) != nil }
    }

    /// Shared semantic color for chips, checkout choices, and card glows.
    static func tint(for tag: Pet.BehaviorTag?) -> Color {
        switch tag {
        case .aggressive: return DS.ColorToken.danger
        case .specialNeeds: return DS.ColorToken.specialCare
        case .anxious, .nervous: return DS.ColorToken.calmBlue
        case .calm, .cooperative: return DS.ColorToken.success
        case nil: return .secondary
        }
    }
    /// Map a raw tag string to a display tuple (emoji, label).
    /// Falls back to just the label when unknown.
    static func display(for raw: String) -> (emoji: String?, label: String) {
        if let kind = Pet.behaviorTagKind(for: raw) {
            switch kind {
            case .calm:
                return ("🧘", Pet.BehaviorTag.calm.displayName)
            case .cooperative:
                return ("🤝", Pet.BehaviorTag.cooperative.displayName)
            case .anxious:
                return ("😟", Pet.BehaviorTag.anxious.displayName)
            case .nervous:
                return ("😬", Pet.BehaviorTag.nervous.displayName)
            case .aggressive:
                return ("🛑", Pet.BehaviorTag.aggressive.displayName)
            case .specialNeeds:
                return ("❤️‍🩹", Pet.BehaviorTag.specialNeeds.displayName)
            }
        }

        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "senior":
            return ("🧓", AppLocalization.localized("pet.behavior.senior", value: "Senior"))
        case "puppy", "puppy / young", "young":
            return ("🐶", AppLocalization.localized("pet.behavior.puppy_young", value: "Puppy / Young"))
        default:
            // Title-case fallback label
            let label = key.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
            return (nil, label)
        }
    }
}
