//
//  PhotoWell.swift
//  Pawtrackr
//
//  Created by Assistant on 9/15/25.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A reusable component that displays a photo, a placeholder, and handles the tap-to-pick-image action.
struct PhotoWell: View {
    @Binding var imageData: Data?
    let title: String
    let allowsEditing: Bool
    let maxDimension: CGFloat
    let jpegQuality: CGFloat

    init(
        imageData: Binding<Data?>,
        title: String,
        allowsEditing: Bool = true,
        maxDimension: CGFloat = 1024,
        jpegQuality: CGFloat = 0.70
    ) {
        self._imageData = imageData
        self.title = title
        self.allowsEditing = allowsEditing
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    var body: some View {
        ImagePicker(
            imageData: $imageData,
            allowsEditing: allowsEditing,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        ) {
            ZStack {
                if let data = imageData {
                    LazyImageDataImage(data: data, maxDimension: 512)
                } else {
                    #if os(macOS)
                    AddPhotoPlaceholder(title: title, subtitle: AppLocalization.localized("photo_well.click_to_add", value: "Click to add"))
                    #else
                    AddPhotoPlaceholder(title: title, subtitle: AppLocalization.localized("photo_well.tap_to_add", value: "Tap to add"))
                    #endif
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        // Without a style the Mac draws the well as a default push button: a
        // dark gray bezel with the placeholder dimmed inside it.
        .pressScaleStyle()
        .accessibilityLabel(title)
        .contextMenu {
            if imageData != nil {
                Button(role: .destructive) {
                    imageData = nil
                } label: {
                    Label(AppLocalization.localized("photo.remove", value: "Remove Photo"), systemImage: "trash")
                }
            }
        }
    }
}

/// Decodes image data asynchronously to keep the UI perfectly fluid.
@MainActor
struct LazyImageDataImage: View {
    let data: Data
    let maxDimension: CGFloat
    
    @State private var image: Image? = nil
    @State private var loadedIdentity: ImageDataIdentity?

    private var identity: ImageDataIdentity {
        ImageDataIdentity(data: data, maxDimension: maxDimension)
    }
    
    var body: some View {
        ZStack {
            if let displayImage {
                displayImage
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .task(id: identity) {
            await loadImage(for: identity)
        }
    }

    private var displayImage: Image? {
        if loadedIdentity == identity, let image {
            return image
        }
        return ImageDataDecodeCache.shared.image(for: identity)
    }
    
    private func loadImage(for identity: ImageDataIdentity) async {
        if let cached = ImageDataDecodeCache.shared.image(for: identity) {
            loadedIdentity = identity
            image = cached
            return
        }

        if loadedIdentity != identity {
            loadedIdentity = identity
            image = nil
        }

        let decoded = await Task.detached(priority: .userInitiated) { () -> Image? in
            #if canImport(UIKit)
            if let ui = ImageCache.shared.image(data: data, maxDimension: maxDimension) {
                return Image(uiImage: ui)
            }
            #elseif canImport(AppKit)
            if let ns = ImageCache.shared.image(data: data, maxDimension: maxDimension) {
                return Image(nsImage: ns)
            }
            #endif
            return nil
        }.value
        
        guard loadedIdentity == identity else { return }
        if let decoded {
            ImageDataDecodeCache.shared.store(decoded, for: identity)
        }
        self.image = decoded
    }
}

private struct ImageDataIdentity: Hashable {
    let count: Int
    let sampleHash: Int
    let maxDimension: Int

    init(data: Data, maxDimension: CGFloat) {
        self.count = data.count
        self.maxDimension = Int(maxDimension.rounded())

        var hash = 5381
        for byte in data.prefix(16) {
            hash = (hash &* 33) &+ Int(byte)
        }
        if data.count > 16 {
            for byte in data.suffix(16) {
                hash = (hash &* 33) &+ Int(byte)
            }
        }
        self.sampleHash = hash
    }
}

@MainActor
private final class ImageDataDecodeCache {
    static let shared = ImageDataDecodeCache()

    private var images: [ImageDataIdentity: Image] = [:]
    private var order: [ImageDataIdentity] = []
    private let countLimit = 200

    private init() {}

    func image(for identity: ImageDataIdentity) -> Image? {
        images[identity]
    }

    func store(_ image: Image, for identity: ImageDataIdentity) {
        if images[identity] == nil {
            order.append(identity)
        }
        images[identity] = image

        while order.count > countLimit {
            let oldest = order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }
}

/// A standardized placeholder for photo wells.
struct AddPhotoPlaceholder: View {
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
            VStack(spacing: 4) {
                Image(systemName: "camera")
                    .font(.title2)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}
