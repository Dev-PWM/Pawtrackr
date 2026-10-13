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
    
    var brandPrimary: Color = Color(red: 99/255,  green: 102/255, blue: 241/255)
    
    private init() {}
    
    func updateBrandColor(hex: String) {
        if let color = Color(hex: hex) {
            brandPrimary = color
        }
    }
}

// Access control alignment: keep DS internal so it can reference internal model types (PetGender, Species) without exposing them in a public API.
enum DS {
    // MARK: - Colors
    enum ColorToken {
        #if os(macOS)
        static let background = Color(nsColor: .windowBackgroundColor)
        static let surface    = Color(nsColor: .underPageBackgroundColor)
        #else
        static let background = Color(.systemGroupedBackground)
        static let surface    = Color(.secondarySystemBackground)
        #endif
        static let border     = Color.gray.opacity(0.15)
        static let shadow     = Color.black.opacity(0.08)

        // Accents
        // Dynamic primary based on ThemeManager
        static var primary: Color { ThemeManager.shared.brandPrimary }
        
        static let success    = Color(red: 16/255,  green: 185/255, blue: 129/255) // #10B981
        /// Teal distinguishes anxiety from amber operational warnings. Labels
        /// always accompany this color; darker ink keeps light-mode contrast.
        static let anxious: Color = {
            #if os(macOS)
            Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(srgbRed: dark ? 94/255 : 15/255,
                               green: dark ? 234/255 : 118/255,
                               blue: dark ? 212/255 : 110/255, alpha: 1)
            })
            #else
            Color(uiColor: UIColor { traits in
                let dark = traits.userInterfaceStyle == .dark
                return UIColor(red: dark ? 94/255 : 15/255,
                               green: dark ? 234/255 : 118/255,
                               blue: dark ? 212/255 : 110/255, alpha: 1)
            })
            #endif
        }()
        static let warning    = Color(red: 245/255, green: 158/255, blue: 11/255)  // #F59E0B
        static let danger     = Color(red: 239/255, green: 68/255,  blue: 68/255)  // #EF4444
        static let info       = Color(red: 59/255,  green: 130/255, blue: 246/255) // #3B82F6
        // Care is semantic, not the customizable brand accent.
        static let specialCare = Color(red: 124/255, green: 58/255, blue: 237/255) // #7C3AED

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
    /// Gender-colored 3pt top bar for cards/screens.
    func genderAccentTopBar(_ gender: PetGender) -> some View {
        self.overlay(alignment: .top) {
            Rectangle().fill(DS.ColorToken.gender(gender)).frame(height: 3)
        }
    }

    /// Circular avatar ring with white stroke + gender ring.
    func avatarRings(gender: PetGender) -> some View {
        self
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .overlay(Circle().stroke(DS.ColorToken.gender(gender).opacity(0.9), lineWidth: 2))
    }

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
