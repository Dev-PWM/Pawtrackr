//
//  DesignSystem.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//

import SwiftUI
import Observation

#if os(macOS)
import AppKit // Import AppKit for NSColor on macOS
#else
import UIKit
#endif

/// Observable theme manager to support dynamic branding across the app.
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var brandPrimary: Color = DS.ColorToken.defaultPrimary

    private init() {}

    func updateBrandColor(hex: String) {
        // Both shipped defaults adapt; custom branding stays intact.
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if ["#6366F1", "6366F1", "#5B4FE9", "5B4FE9"].contains(normalized) {
            brandPrimary = DS.ColorToken.defaultPrimary
        } else if let color = Color(hex: hex) {
            brandPrimary = color
        }
    }
}

// Access control alignment: keep DS internal so it can reference internal model types (PetGender, Species) without exposing them in a public API.
enum DS {
    // MARK: - Colors
    enum ColorToken {
        /// Resolves sRGB palette values in the native view's current appearance.
        static func adaptive(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
            #if os(macOS)
            Color(nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
            })
            #else
            Color(uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
            })
            #endif
        }

        static let background = adaptive(light: 0xF7F6F2, dark: 0x110E14)
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B1720)
        static let surfaceElevated = adaptive(light: 0xFCFCFA, dark: 0x241F2B)
        static let border = adaptive(light: 0xE5E2DC, dark: 0x2E2836)
        static let textPrimary = adaptive(light: 0x141417, dark: 0xF4F2F7)
        static let textSecondary = adaptive(light: 0x5C5A66, dark: 0xA39CAD)
        static let shadow = adaptive(light: 0x141417, dark: 0x110E14, alpha: 0.05)
        static let defaultPrimary = adaptive(light: 0x5B4FE9, dark: 0x7C72FF)

        // Accents
        // Dynamic primary based on ThemeManager
        static var primary: Color { ThemeManager.shared.brandPrimary }

        static let success = adaptive(light: 0x059669, dark: 0x10B981)
        static let calmBlue = adaptive(light: 0x0284C7, dark: 0x0091FF)
        static let anxious = calmBlue
        static let warning = adaptive(light: 0xD97706, dark: 0xF59E0B)
        static let danger = adaptive(light: 0xDC2626, dark: 0xEF4444)
        static let info = calmBlue
        static let specialCare = warning

        static let genderMale = info
        static let genderFemale = Color(red: 236/255, green: 72/255, blue: 153/255) // #EC4899

        // Session (active visit) accent tokens
        static let session           = success                           // primary accent (rails, icons)
        static let sessionBackground = success.opacity(0.12)             // chips / soft fills
        static let sessionText       = success                           // text on the soft chip

        // Gender
        static func gender(_ g: PetGender?) -> Color { (g ?? .male) == .male ? genderMale : genderFemale }

        // Species (soft tints used behind paw/badges)
        static func species(_ s: Species) -> Color {
            switch s {
            case .dog: return .brown
            case .cat: return .orange
            }
        }

        /// Centralized tint used for species+gender badges (Client Center avatars).
        /// We bias the tint by gender for clarity, and keep it soft for backgrounds.
        static func avatarTint(species: Species, gender: PetGender) -> Color {
            let base = DS.ColorToken.gender(gender)
            switch species {
            case .dog, .cat: return base.opacity(0.22)
            }
        }

        /// Top-bar gradient for cards based on gender.
        static func genderGradient(_ gender: PetGender) -> LinearGradient {
            let c = DS.ColorToken.gender(gender)
            return LinearGradient(
                colors: [c.opacity(0.95), c.opacity(0.65)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    // MARK: - Spacing
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs:  CGFloat = 6
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Radii
    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - Rails
    enum Rail {
        static let width: CGFloat = 4
    }

    // MARK: - Typography helpers
    enum TypeScale {
        static let title    = Font.title3.weight(.semibold)
        static let headline = Font.headline
        static let subhead  = Font.subheadline
        static let footnote = Font.footnote
        static let caption  = Font.caption
    }
}

// MARK: - Convenience modifiers
extension View {
    /// Adds a left accent rail. Use with DS.ColorToken.session for active sessions.
    func leftAccentRail(_ color: Color) -> some View {
        overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: DS.Rail.width)
        }
    }

    /// Crisp 1px-equivalent border regardless of device scale.
    func hairlineBorder(_ color: Color, cornerRadius: CGFloat = DS.Radius.md) -> some View {
        modifier(HairlineBorderModifier(color: color, cornerRadius: cornerRadius))
    }

    /// Gender-colored gradient 3pt top bar.
    func genderAccentTopGradient(_ gender: PetGender) -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(DS.ColorToken.genderGradient(gender))
                .frame(height: 3)
        }
    }

    // Note: pressScaleStyle() lives in MotionSystem.swift and supports a
    // hapticsEnabled parameter; do not redeclare it here.
}

private struct HairlineBorderModifier: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    @Environment(\.displayScale) var displayScale

    func body(content: Content) -> some View {
        let width = 1.0 / displayScale
        return content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: width)
        )
    }
}

// MARK: - Hex Extension
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if hexSanitized.hasPrefix("#") {
            hexSanitized.remove(at: hexSanitized.startIndex)
        }

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r, g, b, a: UInt64
        switch hexSanitized.count {
        case 6:
            r = (rgb & 0xFF0000) >> 16
            g = (rgb & 0x00FF00) >> 8
            b = (rgb & 0x0000FF)
            a = 255
        case 8:
            r = (rgb & 0xFF000000) >> 24
            g = (rgb & 0x00FF0000) >> 16
            b = (rgb & 0x0000FF00) >> 8
            a = (rgb & 0x000000FF)
        default:
            return nil
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
