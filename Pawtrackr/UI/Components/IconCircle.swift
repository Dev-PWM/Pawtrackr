//
//  IconCircle.swift
//  Pawtrackr
//
//  Reusable circular icon with configurable content, styles, and badges.
//  - Logic is simplified using a GlyphContent enum for clear rendering paths.
//  - Uses shared helpers for cross-platform image decoding.
//
//  Updated by Assistant on 2025-08-28.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct IconCircle: View {
    // MARK: - Types
    typealias SizeToken = IconSizeToken
    
    enum Style: Equatable {
        case solid(bg: Color, fg: Color)
        case tinted(Color) // bg; fg will default to white
        case auto(species: Species?, gender: PetGender?) // gender/species-aware tinting
    }

    /// Defines the content to be rendered, determined by priority in the initializer.
    private indirect enum GlyphContent {
        case remote(url: URL, fallback: GlyphContent)
        case thumbnail(data: Data, original: Data?)
        case local(data: Data)
        case initials(String)
        case symbol(String)
        case fallback
    }
    
    // MARK: - Properties
    private let sizeToken: SizeToken
    private let style: Style
    private let lineWidth: CGFloat
    private let badgeSystemImage: String?
    private let badgeColor: Color?
    private let accessibilityLabel: String?
    private let isDecorative: Bool
    private let glyphContent: GlyphContent

    // MARK: - Initializer
    
    /// Creates a versatile circular icon.
    ///
    /// The content is determined by priority: `imageURL` > `thumbnailData` > `imageData` > `initials` > `systemImage`.
    ///
    /// - Parameters:
    ///   - systemImage: The name of an SF Symbol to display.
    ///   - initials: A name or string to be converted into initials.
    ///   - imageData: Raw `Data` for a local image.
    ///   - thumbnailData: Small pre-downsampled `Data` for performance.
    ///   - imageURL: A `URL` for a remote image to be loaded asynchronously.
    ///   - size: A predefined or custom size token.
    ///   - style: The color and fill style of the circle.
    ///   - lineWidth: The width of an optional stroke around the circle.
    ///   - badgeSystemImage: An optional SF Symbol to display in a bottom-trailing badge.
    ///   - badgeColor: An optional `Color` for a simple dot badge.
    ///   - accessibilityLabel: A custom label for VoiceOver.
    ///   - isDecorative: If `true`, the icon is ignored by accessibility services.
    public init(systemImage: String? = nil,
                initials: String? = nil,
                imageData: Data? = nil,
                thumbnailData: Data? = nil,
                imageURL: URL? = nil,
                size: SizeToken = .md,
                style: Style = .tinted(Color.accentColor.opacity(0.15)),
                lineWidth: CGFloat = 0,
                badgeSystemImage: String? = nil,
                badgeColor: Color? = nil,
                accessibilityLabel: String? = nil,
                isDecorative: Bool = false) {
        self.sizeToken = size
        self.style = style
        self.lineWidth = lineWidth
        self.badgeSystemImage = badgeSystemImage
        self.badgeColor = badgeColor
        self.accessibilityLabel = accessibilityLabel
        self.isDecorative = isDecorative
        
        // Determine the glyph content based on priority
        let initialsGlyph = Self.makeInitials(from: initials).map { GlyphContent.initials($0) }
        let symbolGlyph = systemImage.map { GlyphContent.symbol($0) }
        let fallback = initialsGlyph ?? symbolGlyph ?? .fallback

        if let url = imageURL {
            self.glyphContent = .remote(url: url, fallback: fallback)
        } else if let thumb = thumbnailData {
            self.glyphContent = .thumbnail(data: thumb, original: imageData)
        } else if let data = imageData {
            self.glyphContent = .local(data: data)
        } else {
            self.glyphContent = fallback
        }
    }

    // MARK: - Body
    var body: some View {
        let dim = sizeToken.diameter
        let tints = self.tints(for: style)

        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(tints.bg)
                .overlay(Circle().strokeBorder(tints.ring, lineWidth: lineWidth > 0 ? lineWidth : 0))
                .frame(width: dim, height: dim)

            glyphView(content: glyphContent, tints: tints)
            
            badgeView(tints: tints)
        }
        .contentShape(Circle())
        .modifier(AccessibilityModifier(
            label: accessibilityLabel,
            defaultLabel: defaultAccessibilityLabel,
            isDecorative: isDecorative
        ))
    }

    // MARK: - Subviews
    
    @ViewBuilder
    private func glyphView(content: GlyphContent, tints: (bg: Color, fg: Color, ring: Color)) -> some View {
        let dim = sizeToken.diameter
        
        switch content {
        case .remote(let url, _):
            CachedAsyncImage(url: url, maxDimension: dim * 2) {
                ZStack { Circle().fill(tints.bg); ProgressView() }
            } failure: {
                Image(systemName: "pawprint.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tints.fg)
            }
            .frame(width: dim, height: dim)
            .clipShape(Circle())

        case .thumbnail(let data, let original):
            AsyncDecodedImage(
                dataSources: [data, original].compactMap { $0 },
                maxDimension: dim * 2
            ) {
                fallbackSymbol(tints: tints)
            }
            .frame(width: dim, height: dim)
            .clipShape(Circle())

        case .local(let data):
            AsyncDecodedImage(
                dataSources: [data],
                maxDimension: dim * 2
            ) {
                fallbackSymbol(tints: tints)
            }
            .frame(width: dim, height: dim)
            .clipShape(Circle())

        case .initials(let text):
            Text(text)
                .font(.system(size: dim * sizeToken.iconScale, weight: sizeToken.fontWeight, design: .rounded))
                .foregroundStyle(tints.fg)

        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: dim * sizeToken.iconScale, weight: sizeToken.fontWeight))
                .foregroundStyle(tints.fg)

        case .fallback:
            fallbackSymbol(tints: tints)
        }
    }

    private func fallbackSymbol(tints: (bg: Color, fg: Color, ring: Color)) -> some View {
        let dim = sizeToken.diameter
        return Image(systemName: "pawprint.fill")
            .font(.system(size: dim * sizeToken.iconScale, weight: sizeToken.fontWeight))
            .foregroundStyle(tints.fg)
    }
    
    @ViewBuilder
    private func badgeView(tints: (bg: Color, fg: Color, ring: Color)) -> some View {
        let dim = sizeToken.diameter
        let badgeOffset = dim * 0.08
        
        if let badgeSystemImage {
            let badgeDim = max(14, dim * 0.36)
            Image(systemName: badgeSystemImage)
                .font(.system(size: badgeDim * 0.55, weight: .bold))
                .foregroundStyle(tints.fg)
                .frame(width: badgeDim, height: badgeDim)
                .background(Circle().fill(.thickMaterial))
                .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                .offset(x: badgeOffset, y: badgeOffset)
                .accessibilityHidden(true)
        } else if let badgeColor {
            let badgeDim = max(10, dim * 0.22)
            Circle()
                .fill(badgeColor)
                .frame(width: badgeDim, height: badgeDim)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .offset(x: badgeOffset, y: badgeOffset)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Private Helpers
    
    private func tints(for style: Style) -> (bg: Color, fg: Color, ring: Color) {
        switch style {
        case .solid(let bg, let fg):
            return (bg, fg, fg.opacity(0.85))

        case .tinted(let bg):
            return (bg, .primary, .primary.opacity(0.65))

        case .auto(_, let gender):
            if let gender {
                let base = DS.ColorToken.gender(gender)
                return (base.opacity(0.15), .primary, base.opacity(0.65))
            } else {
                let base = Color.secondary.opacity(0.55)
                return (base.opacity(0.15), .primary, base.opacity(0.65))
            }
        }
    }

    private var defaultAccessibilityLabel: String {
        switch glyphContent {
        case .initials(let str): return String(format: AppLocalization.localized("icon_circle.initials_fmt", value: "Avatar with initials %@"), str)
        case .symbol(let name): return name.replacingOccurrences(of: ".", with: " ") + " icon"
        default: return AppLocalization.localized("icon_circle.avatar", value: "Avatar")
        }
    }
}

// MARK: - Convenience Initializers & Utilities
extension IconCircle {
    /// Creates a pet-specific avatar using the `.auto` style for gender-aware tinting.
    init(pet: Pet, size: SizeToken = .md, badge: String? = nil) {
        self.init(
            systemImage: (pet.species == Species.cat) ? "cat.fill" : "dog.fill", // More specific icons
            initials: pet.name,
            imageData: pet.photoData,
            size: size,
            style: .auto(species: pet.species, gender: pet.gender),
            badgeSystemImage: badge
        )
    }
    
    /// A robust utility to generate initials from a name string.
    static func makeInitials(from name: String?) -> String? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let initials = parts.compactMap { part -> String? in
            guard let first = part.first else { return nil }
            // Emoji graphemes must retain their joiners, modifiers and selectors.
            if first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x200D }) {
                return String(first)
            }
            let composed = String(first).precomposedStringWithCanonicalMapping
            let clean = composed.unicodeScalars.filter {
                !CharacterSet.nonBaseCharacters.contains($0) && !CharacterSet.controlCharacters.contains($0)
            }
            return String(String.UnicodeScalarView(clean)).uppercased()
        }.joined()
        return initials.isEmpty ? nil : initials
    }
}

// MARK: - Private Modifier
private struct AccessibilityModifier: ViewModifier {
    let label: String?
    let defaultLabel: String
    let isDecorative: Bool
    
    func body(content: Content) -> some View {
        if isDecorative {
            content.accessibilityHidden(true)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label ?? defaultLabel))
                .accessibilityAddTraits(.isImage)
        }
    }
}

// MARK: - Data → SwiftUI Image helper
private extension Image {
    init?(platformImage data: Data) {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) {
            self = Image(uiImage: ui)
        } else { return nil }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) {
            self = Image(nsImage: ns)
        } else { return nil }
        #else
        return nil
        #endif
    }
}

// MARK: - Async-decoded image (off-main decode, cached via ImageCache)

private struct AsyncDecodedImage<Fallback: View>: View {
    let dataSources: [Data]
    let maxDimension: CGFloat
    @ViewBuilder var fallback: () -> Fallback

    #if canImport(UIKit)
    @State private var decoded: UIImage?
    #elseif canImport(AppKit)
    @State private var decoded: NSImage?
    #endif

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback()
            }
            #elseif canImport(AppKit)
            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback()
            }
            #endif
        }
        .task(id: decodeRequest) {
            await decode()
        }
    }

    private struct DecodeRequest: Equatable {
        let sources: [Data]
        let dimension: CGFloat
    }

    private var decodeRequest: DecodeRequest {
        DecodeRequest(sources: dataSources, dimension: maxDimension)
    }

    private func decode() async {
        let sources = dataSources
        let dim = maxDimension
        #if canImport(UIKit)
        let result: UIImage? = await Task.detached(priority: .userInitiated) {
            for data in sources {
                if let img = ImageCache.shared.image(data: data, maxDimension: dim) {
                    return img
                }
            }
            return nil
        }.value
        #elseif canImport(AppKit)
        let boxed: SendableImageBox = await Task.detached(priority: .userInitiated) {
            for data in sources {
                if let img = ImageCache.shared.image(data: data, maxDimension: dim) {
                    return SendableImageBox(image: img)
                }
            }
            return SendableImageBox(image: nil)
        }.value
        let result: NSImage? = boxed.image
        #endif
        guard !Task.isCancelled else { return }
        decoded = result
    }
}

#if canImport(AppKit)
/// NSImage is not Sendable; this box transports an immutable decoded NSImage across actors.
private struct SendableImageBox: @unchecked Sendable {
    let image: NSImage?
}
#endif
