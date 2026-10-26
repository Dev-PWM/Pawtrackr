//
//  FAB.swift
//  Pawtrackr
//
//  Reusable Floating Action Button
//  - Blue gradient circular button with shadow
//  - Default system image: plus
//  - Haptic tap
//  - "fabOverlay" modifier to pin it bottom‑trailing over any content
//
//  Created by mac on 8/14/25.
//  Updated by mac on 8/16/25.
//

import OSLog
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct FAB: View {
    public var diameter: CGFloat = 56
    public var systemImage: String = "plus"
    public var accessibilityLabel: String = "Add New"
    public var enableHaptics: Bool = true
    public var isLoading: Bool = false
    public var badgeCount: Int? = nil
    public var badgeBackground: Color = .red
    public var badgeTint: Color = .white
    public var isDisabled: Bool = false
    public var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public enum Size {
        case small, regular, large
        var diameter: CGFloat {
            switch self { case .small: return 44; case .regular: return 56; case .large: return 64 }
        }
    }

    public enum Style {
        case primary, secondary, destructive
    }

    public var size: Size = .regular
    public var style: Style = .primary
    public var tint: Color = .accentColor

    private var effectiveDiameter: CGFloat {
        // Respect custom diameter if the caller changed it; otherwise use size preset
        (diameter != 56) ? diameter : size.diameter
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return tint
        case .secondary: return tint.opacity(0.9)
        case .destructive: return Color.red
        }
    }

    public init(
        diameter: CGFloat = 56,
        systemImage: String = "plus",
        accessibilityLabel: String = "Add New",
        enableHaptics: Bool = true,
        isLoading: Bool = false,
        size: Size = .regular,
        style: Style = .primary,
        tint: Color = .accentColor,
        badgeCount: Int? = nil,
        badgeBackground: Color = .red,
        badgeTint: Color = .white,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.diameter = diameter
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.enableHaptics = enableHaptics
        self.isLoading = isLoading
        self.size = size
        self.style = style
        self.tint = tint
        self.badgeCount = badgeCount
        self.badgeBackground = badgeBackground
        self.badgeTint = badgeTint
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: tap) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .frame(width: effectiveDiameter, height: effectiveDiameter)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: effectiveDiameter, height: effectiveDiameter)
                }
            }
            .frame(width: effectiveDiameter, height: effectiveDiameter)
            .background(Circle().fill(backgroundColor))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 4)
            .contentShape(Circle())
            .overlay(alignment: .topTrailing) {
                if let count = badgeCount, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeBackground))
                        .offset(x: 8, y: -8)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValueText))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(AppLocalization.localized("a11y.primary_action")))
        .keyboardShortcut(.defaultAction)
        .opacity(isDisabled ? 0.6 : 1.0)
        .buttonStyle(PressedScaleStyle())
        .disabled(isDisabled || isLoading)
        .accessibilityRespondsToUserInteraction(!(isDisabled || isLoading))
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
        }
        .scaleEffect(isHovering ? 1.06 : 1.0)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
    }

    private var accessibilityValueText: String {
        if isLoading { return "Loading" }
        if let count = badgeCount, count > 0 { return "\(min(count, 99)) notifications" }
        return ""
    }

    private func tap() {
        guard !isLoading, !isDisabled else { return }
        if enableHaptics { HapticManager.impact(.light) }
        action()
    }
}

private struct PressedScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(reduceMotion ? nil : Animations.interactiveSpring, value: configuration.isPressed)
    }
}

// MARK: - Overlay helper

public struct FABOverlayModifier<FabContent: View>: ViewModifier {
    let alignment: Alignment
    let padding: EdgeInsets
    let padForSafeArea: Bool
    let fab: () -> FabContent

    public init(
        alignment: Alignment = .bottomTrailing,
        padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 24),
        padForSafeArea: Bool = true,
        @ViewBuilder fab: @escaping () -> FabContent
    ) {
        self.alignment = alignment
        self.padding = padding
        self.padForSafeArea = padForSafeArea
        self.fab = fab
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            fab()
                .padding(padding)
                .padding(.bottom, padForSafeArea ? max(0, bottomSafeAreaInset() - 4) : 0)
                .ignoresSafeArea(edges: [.bottom])
        }
    }
}

#if os(iOS)
private func bottomSafeAreaInset() -> CGFloat {
    // Best-effort lookup; fine for in-app usage and previews
    return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 0
}
#else
private func bottomSafeAreaInset() -> CGFloat { 0 }
#endif

public extension View {
    /// Pins a Floating Action Button to the given alignment (default bottom‑trailing).
    /// Usage:
    /// ```swift
    /// someView
    ///   .fabOverlay { FAB { /* action */ } }
    /// ```
    /// Note: Positioning of the FAB can also be handled by the parent view using `.position()` if desired.
    func fabOverlay<FabContent: View>(
        alignment: Alignment = .bottomTrailing,
        padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 24),
        padForSafeArea: Bool = true,
        @ViewBuilder _ fab: @escaping () -> FabContent
    ) -> some View {
        modifier(FABOverlayModifier(alignment: alignment, padding: padding, padForSafeArea: padForSafeArea, fab: fab))
    }
}

// MARK: - Preview

struct FAB_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZStack {
                #if os(macOS)
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                #else
                Color(UIColor.systemBackground).ignoresSafeArea()
                #endif
                Text("Content")
            }
            .fabOverlay {
                FAB(size: .regular, style: .primary, tint: .accentColor) {
                    Logger.ui.debug("FAB tapped")
                }
                // Note: do NOT add .accessibilityLabel here — FAB sets its own
                // dynamic label internally and outer modifiers would shadow it.
            }
            .previewDisplayName("Default")

            ZStack {
                #if os(macOS)
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                #else
                Color(UIColor.systemBackground).ignoresSafeArea()
                #endif
                Text("Loading FAB")
            }
            .fabOverlay {
                FAB(isLoading: true, style: .destructive, tint: .red) {
                    // no-op while loading
                }
            }
            .previewDisplayName("Loading")

            ZStack {
                #if os(macOS)
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                #else
                Color(UIColor.systemBackground).ignoresSafeArea()
                #endif
                Text("With Badge")
            }
            .fabOverlay {
                FAB(size: .regular, style: .primary, tint: .accentColor, badgeCount: 7) {
                    Logger.ui.debug("FAB tapped with badge")
                }
            }
            .previewDisplayName("Badge")
        }
    }
}
