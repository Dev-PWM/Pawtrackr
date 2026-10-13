//
//  Chip.swift
//  Pawtrackr
//
//  A unified, highly configurable chip component for tags, filters, and actions.
//  This component merges the functionality of the previous `Pill` and `Chip` files.
//
//  Created by mac on 8/20/25.
//  Updated by Assistant on 8/28/25.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

public struct Chip: View {
    // MARK: - Configuration Enums
    
    public enum Style: Equatable {
        case filled, outline, tinted, prominent
    }

    public enum Size: CaseIterable {
        case xs, sm, md, lg
    }
    
    public enum Semantic {
        case info, success, warning, danger, genderMale, genderFemale, neutral
    }

    // MARK: - Properties
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering: Bool = false

    private let text: String
    private let systemImage: String?
    private let style: Style
    private let size: Size
    private let tint: Color
    private let onTap: (() -> Void)?
    @Binding private var isSelected: Bool
    private let semantic: Semantic?


    // MARK: - Initializer
    
    /// The designated initializer for creating a custom chip. For most cases, use the static convenience methods.
    public init(
        _ text: String,
        systemImage: String? = nil,
        style: Style = .filled,
        size: Size = .md,
        tint: Color = .accentColor,
        isSelected: Binding<Bool> = .constant(false),
        onTap: (() -> Void)? = nil
    ) {
        self.text = text
        self.systemImage = systemImage
        self.style = style
        self.size = size
        self.tint = tint
        self._isSelected = isSelected
        self.onTap = onTap
        self.semantic = nil
    }
    
    private init(
        semantic text: String,
        systemImage: String? = nil,
        type: Semantic,
        size: Size = .md
    ) {
        self.text = text
        self.systemImage = systemImage
        self.style = .filled // default, will be overridden by semantic logic
        self.size = size
        self.tint = .accentColor // default, will be overridden by semantic logic
        self._isSelected = .constant(false)
        self.onTap = nil
        self.semantic = type
    }

    // MARK: - Body
    public var body: some View {
        let metrics = self.metrics(for: size)
        
        let (finalStyle, finalTint) = {
            if let semantic = semantic {
                return Appearance(colorScheme: colorScheme).style(for: semantic)
            }
            return (style, tint)
        }()
        
        let colors = self.colors(for: finalStyle, isSelected: isSelected, tint: finalTint)

        Button(action: handleTap) {
            label(metrics: metrics, colors: colors)
        }
        .buttonStyle(ChipButtonStyle(isHovering: $isHovering))
        .background(colors.bg, in: Capsule())
        .overlay(
            Capsule().strokeBorder(colors.stroke, lineWidth: colors.stroke == .clear ? 0 : 1 / max(displayScale, 1))
        )
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .opacity(isEnabled ? 1 : 0.5)
        .chipAccessibility(label: text, isSelected: isSelected, hasTapHandler: onTap != nil)
    }
    
    private func handleTap() {
        HapticManager.selectionChanged()
        if let onTap {
            onTap()
        } else {
            isSelected.toggle()
        }
    }
    
    @ViewBuilder
    private func label(metrics: ChipMetrics, colors: ChipColors) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.medium)
            }
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(metrics.font)
        .fontWeight(.semibold)
        .foregroundStyle(colors.fg)
        .padding(.horizontal, metrics.hPadding)
        .padding(.vertical, metrics.vPadding)
    }
}


// MARK: - Convenience Initializers (Static Methods)

public extension Chip {
    /// Creates a chip that acts as a simple action button.
    static func action(_ text: String, systemImage: String? = nil, style: Style = .filled, size: Size = .md, tint: Color = .accentColor, onTap: @escaping () -> Void) -> Chip {
        Chip(text, systemImage: systemImage, style: style, size: size, tint: tint, onTap: onTap)
    }

    /// Creates a chip that acts as a toggle, binding to a boolean state.
    static func selectable(_ text: String, systemImage: String? = nil, isSelected: Binding<Bool>, style: Style = .filled, size: Size = .md, tint: Color = .accentColor) -> Chip {
        Chip(text, systemImage: systemImage, style: style, size: size, tint: tint, isSelected: isSelected)
    }
    
    /// Creates a chip with a predefined semantic style.
    static func semantic(_ text: String, systemImage: String? = nil, semantic: Semantic, size: Size = .md) -> Chip {
        Chip(semantic: text, systemImage: systemImage, type: semantic, size: size)
    }
    
    // Semantic helpers
    static func success(_ text: String, systemImage: String? = "checkmark.circle.fill", size: Size = .md) -> Chip {
        .semantic(text, systemImage: systemImage, semantic: .success, size: size)
    }
    static func warning(_ text: String, systemImage: String? = "exclamationmark.triangle.fill", size: Size = .md) -> Chip {
        .semantic(text, systemImage: systemImage, semantic: .warning, size: size)
    }
    static func danger(_ text: String, systemImage: String? = "xmark.octagon.fill", size: Size = .md) -> Chip {
        .semantic(text, systemImage: systemImage, semantic: .danger, size: size)
    }
    static func info(_ text: String, systemImage: String? = "info.circle.fill", size: Size = .md) -> Chip {
        .semantic(text, systemImage: systemImage, semantic: .info, size: size)
    }
}


// MARK: - Styling & Theming

fileprivate typealias ChipMetrics = (hPadding: CGFloat, vPadding: CGFloat, font: Font)
fileprivate typealias ChipColors = (bg: Color, fg: Color, stroke: Color)

private extension Chip {
    func metrics(for size: Size) -> ChipMetrics {
        switch size {
        case .xs: (8, 4, .caption2)
        case .sm: (10, 6, .caption)
        case .md: (12, 7, .callout)
        case .lg: (14, 8, .subheadline)
        }
    }

    func colors(for style: Style, isSelected: Bool, tint: Color) -> ChipColors {
        let appearance = Appearance(colorScheme: colorScheme)
        
        switch style {
        case .filled:
            return isSelected ? (tint, .white, .clear) : (appearance.baseBg, appearance.text, appearance.stroke)
        case .outline:
            return isSelected ? (tint.opacity(0.15), tint, tint) : (.clear, appearance.text, appearance.stroke)
        case .tinted:
            let bg = tint.opacity(isSelected ? 0.25 : 0.12)
            let fg = isSelected ? tint : appearance.text
            return (bg, fg, .clear)
        case .prominent:
            return (tint, .white, .clear)
        }
    }
}

// MARK: - Private Appearance Struct
private struct Appearance {
    let colorScheme: ColorScheme
    
    // Base Colors
    var baseBg: Color { colorScheme == .dark ? .secondarySystemBackground : .systemBackground }
    var text: Color { .primary }
    var stroke: Color { Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.15) }
    
    // Semantic Colors
    func style(for semantic: Chip.Semantic) -> (Chip.Style, Color) {
        switch semantic {
        case .info: (.tinted, .blue)
        case .success: (.tinted, .green)
        case .warning: (.tinted, .orange)
        case .danger: (.tinted, .red)
        case .genderMale: (.tinted, .blue)
        case .genderFemale: (.tinted, .pink)
        case .neutral: (.filled, .primary)
        }
    }
}

// MARK: - Private Button Style
private struct ChipButtonStyle: ButtonStyle {
    @Binding var isHovering: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .overlay(
                Group {
                    #if os(macOS)
                    Capsule().fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                    #else
                    EmptyView()
                    #endif
                }
            )
            #if os(macOS)
            .onHover { over in isHovering = over }
            #endif
    }
}

private extension View {
    func chipAccessibility(label: String, isSelected: Bool, hasTapHandler: Bool) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(hasTapHandler ? "" : (isSelected ? "Selected" : "Not selected"))
            .accessibilityHint(hasTapHandler ? "Performs action" : "Toggles selection")
    }
}

// MARK: - Platform Color Compatibility
fileprivate extension Color {
    static var systemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
    
    static var secondarySystemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}
