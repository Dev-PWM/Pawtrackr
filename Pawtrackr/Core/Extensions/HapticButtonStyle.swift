import SwiftUI

/// The legacy entry point shares the same disabled-state and Reduce Motion behavior.
struct HapticPressButtonStyle: ButtonStyle {
    let style: HapticManager.Impact

    func makeBody(configuration: Configuration) -> some View {
        PressScaleButtonStyle(hapticsEnabled: true, hapticStyle: style).makeBody(configuration: configuration)
    }
}

extension View {
    /// Applies an impact style through the centralized native feedback policy.
    func hapticButtonStyle(_ style: HapticManager.Impact = .soft) -> some View {
        buttonStyle(HapticPressButtonStyle(style: style))
    }
}
