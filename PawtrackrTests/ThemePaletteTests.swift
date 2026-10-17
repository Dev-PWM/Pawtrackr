import XCTest
import SwiftUI
@testable import Pawtrackr

#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class ThemePaletteTests: XCTestCase {
    func testNativeColorsResolveForBothAppearances() throws {
        let light = try components(DS.ColorToken.background, dark: false)
        let dark = try components(DS.ColorToken.background, dark: true)
        XCTAssertEqual(light[0], 247.0 / 255, accuracy: 0.001)
        XCTAssertEqual(dark[0], 17.0 / 255, accuracy: 0.001)
        XCTAssertGreaterThan(dark.min() ?? 0, 0, "Dark canvas must retain its plum pigment.")
        XCTAssertNotEqual(light, dark)
    }

    func testSecondaryTextMeetsAAOnEverySurface() throws {
        for dark in [false, true] {
            let text = try components(DS.ColorToken.textSecondary, dark: dark)
            for surface in [DS.ColorToken.background, DS.ColorToken.surface, DS.ColorToken.surfaceElevated] {
                let background = try components(surface, dark: dark)
                let values = [luminance(text), luminance(background)].sorted()
                XCTAssertGreaterThanOrEqual((values[1] + 0.05) / (values[0] + 0.05), 4.5)
            }
        }
    }

    func testLegacyDefaultAdaptsAndCustomBrandSurvives() throws {
        let manager = ThemeManager.shared
        let original = manager.brandPrimary
        defer { manager.brandPrimary = original }

        manager.updateBrandColor(hex: "#6366F1")
        XCTAssertNotEqual(try components(manager.brandPrimary, dark: false),
                          try components(manager.brandPrimary, dark: true))
        manager.updateBrandColor(hex: "#123456")
        XCTAssertEqual(try components(manager.brandPrimary, dark: false),
                       try components(manager.brandPrimary, dark: true))
        XCTAssertEqual(try components(manager.brandPrimary, dark: true)[0], 18.0 / 255, accuracy: 0.001)
    }

    private func components(_ color: Color, dark: Bool) throws -> [Double] {
        #if os(iOS)
        let native = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(native.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [Double(red), Double(green), Double(blue)]
        #else
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var native: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            native = NSColor(color).usingColorSpace(.sRGB)
        }
        let resolved = try XCTUnwrap(native)
        return [Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent)]
        #endif
    }

    private func luminance(_ components: [Double]) -> Double {
        let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
