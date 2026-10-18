//
//  GlassSurface.swift
//  Pawtrackr
//
//  A card surface that adopts Liquid Glass where the OS provides it.
//

import SwiftUI

extension View {
    /// Places the view on a rounded card surface.
    ///
    /// On iOS 26 / macOS 26 and later this is the system Liquid Glass material,
    /// optionally tinted. Earlier systems get the app's standard card: the
    /// `DS.ColorToken.surface` fill with a hairline border.
    ///
    /// - Parameters:
    ///   - cornerRadius: Corner radius of the card shape.
    ///   - tint: An optional color the glass picks up. Ignored by the fallback card.
    func glassSurface(cornerRadius: CGFloat = DS.Radius.lg, tint: Color? = nil) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .hairlineBorder(DS.ColorToken.border, cornerRadius: cornerRadius)
        }
    }
}
