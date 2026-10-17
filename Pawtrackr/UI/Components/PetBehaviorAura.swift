import SwiftUI

/// A restrained handling cue that never intercepts pet actions or Academy targets.
private struct PetBehaviorAura: ViewModifier {
    let pet: Pet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var resourceAllowsAnimation = MotionGovernor.shouldAnimate(reduceMotion: false)

    private var shouldAnimate: Bool {
        resourceAllowsAnimation && !reduceMotion && scenePhase == .active
    }

    private var tint: Color? {
        pet.prominentBehavior.map { BehaviorTagIcons.tint(for: $0) }
    }

    func body(content: Content) -> some View {
        content
            .background {
                if let tint, shouldAnimate {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(tint.opacity(0.10))
                        .blur(radius: 12)
                        .padding(-3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if let tint {
                    Group {
                        if shouldAnimate {
                            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AngularGradient(colors: [tint.opacity(0.95), tint.opacity(0.35), tint.opacity(0.95)], center: .center, angle: .degrees(phase)), lineWidth: 3)
                                    .shadow(color: tint.opacity(0.55), radius: colorScheme == .dark ? 10 : 5)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: DispatchQueue.main)) { _ in
                resourceAllowsAnimation = MotionGovernor.shouldAnimate(reduceMotion: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: DispatchQueue.main)) { _ in
                resourceAllowsAnimation = MotionGovernor.shouldAnimate(reduceMotion: false)
            }
    }
}

extension View {
    /// Adds an accessible, foreground-only behavior aura around a pet surface.
    func petBehaviorAura(pet: Pet) -> some View {
        modifier(PetBehaviorAura(pet: pet))
    }
}
