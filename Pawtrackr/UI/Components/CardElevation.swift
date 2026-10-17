//
//  CardElevation.swift
//  Pawtrackr
//
//  Created by mac on 9/2/25.
//

import SwiftUI

/// Semantic elevation levels for cards/containers used across Pawtrackr.
/// Matches the visual language used in Card.swift (flat/regular/raised).
public enum CardElevationLevel: Equatable, CaseIterable {
    case flat      // no shadow, used for nested or grouped cards
    case regular   // subtle shadow suitable for lists
    case raised    // more prominent surface, for tappable/hovered content
}

/// A cross‑platform shadow recipe that adapts to color scheme and platform.
private struct CardElevationModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    var level: CardElevationLevel

    func body(content: Content) -> some View {
        // We deliberately apply platform-tuned shadows. On iOS we use a two-pass shadow
        // for softer penumbra; on macOS keep it subtler and tighter.
        #if os(iOS) || os(tvOS) || os(visionOS)
        switch level {
        case .flat:
            content
        case .regular:
            content
                .shadow(color: shadowColor(opacity: scheme == .dark ? 0 : 0.05), radius: 8, x: 0, y: 3)
        case .raised:
            content
                .shadow(color: shadowColor(opacity: scheme == .dark ? 0 : 0.06), radius: 14, x: 0, y: 6)
        }
        #elseif os(macOS)
        // On macOS, windows already cast shadows; keep component shadows restrained
        // and respect inactive window states.
        let baseOpacity: CGFloat = (scheme == .dark ? 0 : 0.05)
        let inactiveScale: CGFloat = (controlActiveState == .inactive ? 0.6 : 1.0)
        switch level {
        case .flat:
            content
        case .regular:
            content.shadow(color: shadowColor(opacity: baseOpacity * 0.9 * inactiveScale), radius: 8, x: 0, y: 3)
        case .raised:
            content.shadow(color: shadowColor(opacity: baseOpacity * 1.2 * inactiveScale), radius: 14, x: 0, y: 6)
        }
        #else
        content // default: no special handling
        #endif
    }

    private func shadowColor(opacity: CGFloat) -> Color {
        // Neutral depth keeps colored behavior and reward glows distinct.
        DS.ColorToken.adaptive(light: 0x141417, dark: 0x110E14).opacity(opacity)
    }
}

public extension View {
    /// Applies a standardized card elevation. Use this instead of ad‑hoc shadows so
    /// elevations remain consistent throughout the app.
    func cardElevation(_ level: CardElevationLevel) -> some View {
        modifier(CardElevationModifier(level: level))
    }

    /// Convenience for conditionally applying elevation (e.g., on hover or press).
    func cardElevation(_ level: CardElevationLevel, when condition: Bool) -> some View {
        modifier(CardElevationModifier(level: condition ? level : .flat))
    }
}

// MARK: - Previews
#if DEBUG
struct CardElevation_Previews: PreviewProvider {
    @ViewBuilder
    static var previews: some View {
        Group {
            VStack(spacing: 24) {
                Text("Flat")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .cardElevation(.flat)

                Text("Regular")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .cardElevation(.regular)

                Text("Raised")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .cardElevation(.raised)
            }
            .padding()
            .background(Color.secondary.opacity(0.15))
            .previewDisplayName("iOS / Light")

            VStack(spacing: 24) {
                Text("Raised (Dark)")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .cardElevation(.raised)
            }
            .padding()
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .previewDisplayName("iOS / Dark")
        }
        .previewLayout(.sizeThatFits)
    }
}
#endif
