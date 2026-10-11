import Foundation

/// Legacy tour preferences retained to read existing local settings.
/// Setup no longer asks for a role; everyone receives the same Academy.
enum OnboardingRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case ownerManager
    case frontDeskGroomer

    var id: String { rawValue }
}
