import SwiftUI

/// A restrained handling cue that never intercepts pet actions or Academy targets.
private struct PetBehaviorAura: ViewModifier {
    let pet: Pet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var tint: Color? {
        pet.prominentBehavior.map { BehaviorTagIcons.tint(for: $0) }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let tint {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !MotionGovernor.shouldAnimate(reduceMotion: reduceMotion) || scenePhase != .active)) { timeline in
                        let phase = MotionGovernor.shouldAnimate(reduceMotion: reduceMotion) ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360 : 0
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AngularGradient(colors: [tint.opacity(0.95), tint.opacity(0.35), tint.opacity(0.95)], center: .center, angle: .degrees(phase)), lineWidth: 2)
                    .shadow(color: tint.opacity(0.55), radius: 8)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Adds an accessible, foreground-only behavior aura around a pet surface.
    func petBehaviorAura(pet: Pet) -> some View {
        modifier(PetBehaviorAura(pet: pet))
    }
}
