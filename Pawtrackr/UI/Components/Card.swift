//
//  Card.swift
//  Pawtrackr
//
//  Lightweight, flexible container with rounded corners, shadows, and accents.
//
//  Created by mac on 8/14/25.
//  Updated by Assistant on 8/28/25.
//

import SwiftUI

// MARK: - Core Card View

/// A highly configurable container view that provides a consistent background, border, and shadow.
public struct Card<Content: View>: View {
    #if os(macOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    #endif

    // MARK: Configuration
    private let cornerRadius: CGFloat
    private let padding: EdgeInsets
    private let background: Color
    private let elevation: CardElevationLevel
    private let showBorder: Bool
    private let hoverRaises: Bool
    private let accent: Accent?
    private let onTap: (() -> Void)?
    private let accessibilityLabelText: String?
    @ViewBuilder private var content: () -> Content

    /// Creates a new card view.
    /// - Parameters:
    ///   - cornerRadius: The corner radius for the card's shape.
    ///   - padding: The padding applied inside the card, around the content.
    ///   - background: The background color. Defaults to the adaptive card surface.
    ///   - elevation: The shadow style to apply.
    ///   - showBorder: If `true`, a thin separator border is drawn.
    ///   - hoverRaises: If `true`, the card's shadow elevates on hover (macOS only).
    ///   - accent: An optional accent line to apply to one of the card's edges.
    ///   - accessibilityLabel: A specific label for VoiceOver.
    ///   - onTap: An optional closure to execute on tap, making the card behave like a button.
    ///   - content: The view content to display inside the card.
    public init(
        cornerRadius: CGFloat = 16,
        padding: EdgeInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
        background: Color? = nil,
        elevation: CardElevationLevel = .regular,
        showBorder: Bool = true,
        hoverRaises: Bool = true,
        accent: Accent? = nil,
        accessibilityLabel: String? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.background = background ?? (elevation == .raised ? DS.ColorToken.surfaceElevated : DS.ColorToken.surface)
        self.elevation = elevation
        self.showBorder = showBorder
        self.hoverRaises = hoverRaises
        self.accent = accent
        self.accessibilityLabelText = accessibilityLabel
        self.onTap = onTap
        self.content = content
    }

    public var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { cardBody }
                    .buttonStyle(ScaleOnPressStyle())
                    .accessibilityAddTraits(.isButton)
            } else {
                cardBody
            }
        }
        .withAccessibilityLabel(accessibilityLabelText)
        .accessibilityElement(children: .contain)
    }

    private var cardBody: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        
        return content()
            .foregroundStyle(DS.ColorToken.textPrimary, DS.ColorToken.textSecondary)
            .padding(padding)
            .background(background)
            .clipShape(shape)
            .contentShape(shape)
            // Apply standardized elevation; on macOS optionally raise on hover
            .cardElevation(isHoveredIfEnabled ? .raised : elevation)
            .overlay(borderAndAccentOverlay(for: shape))
            #if os(macOS)
            .scaleEffect(isHoveredIfEnabled ? 1.012 : 1.0)
            .animation(
                MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion),
                value: isHoveredIfEnabled
            )
            .onHover { hovering in
                if hoverRaises { isHovered = hovering }
            }
            #endif
    }
}

// MARK: - Accent Configuration
extension Card {
    public enum AccentEdge {
        case top, leading, bottom, trailing
        
        fileprivate var alignment: Alignment {
            switch self {
            case .top: .top
            case .leading: .leading
            case .bottom: .bottom
            case .trailing: .trailing
            }
        }
        
        fileprivate var frameAxis: Axis.Set {
            switch self {
            case .top, .bottom: .horizontal
            case .leading, .trailing: .vertical
            }
        }
    }

    public enum AccentStyle {
        case color(Color)
        case gradient(LinearGradient)
    }

    public struct Accent {
        let edge: AccentEdge
        let style: AccentStyle
        let thickness: CGFloat
        
        public static func top(_ style: AccentStyle, thickness: CGFloat = 3) -> Accent {
            Accent(edge: .top, style: style, thickness: thickness)
        }
        public static func leading(_ style: AccentStyle, thickness: CGFloat = 4) -> Accent {
            Accent(edge: .leading, style: style, thickness: thickness)
        }
    }
}

// MARK: - Private Helpers
private extension Card {
    var isHoveredIfEnabled: Bool {
        #if os(macOS)
        return hoverRaises && isHovered
        #else
        return false
        #endif
    }

    @ViewBuilder
    func borderAndAccentOverlay(for shape: RoundedRectangle) -> some View {
        if showBorder || accent != nil {
            ZStack(alignment: accent?.edge.alignment ?? .top) {
                if showBorder {
                    shape.strokeBorder(separatorColor, lineWidth: 1)
                }
                if let accent {
                    accentView(for: accent, in: shape)
                }
            }
        }
    }
    
    @ViewBuilder
    func accentView(for accent: Accent, in shape: RoundedRectangle) -> some View {
        let accentShape = Rectangle()
        
        Group {
            switch accent.style {
            case .color(let color):
                accentShape.fill(color)
            case .gradient(let gradient):
                accentShape.fill(gradient)
            }
        }
        .frame(
            width: accent.edge.frameAxis == .vertical ? accent.thickness : nil,
            height: accent.edge.frameAxis == .horizontal ? accent.thickness : nil
        )
        .clipShape(shape) // Clip the accent to the card's rounded corners
    }

    var separatorColor: Color {
        DS.ColorToken.border
    }
}

// MARK: - Modifiers & Styles
private struct ScaleOnPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(
                MotionSystem.resolved(.spring(response: 0.25, dampingFraction: 0.75), reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    HapticManager.impact(.light)
                }
            }
    }
}

fileprivate extension View {
    @ViewBuilder
    func withAccessibilityLabel(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            self.accessibilityLabel(text)
        } else {
            self
        }
    }
}
