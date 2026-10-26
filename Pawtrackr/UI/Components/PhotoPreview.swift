//
//  PhotoPreview.swift
//  Pawtrackr
//
//  Full-screen, accessible photo preview with pinch-to-zoom and pan.
//  Used by VisitDetailView to preview Before/After photos.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct PhotoPreview: View {
    let imageData: Data
    let title: String
    @Environment(\.dismiss) private var dismiss

    // Simple zoom/pan state using gestures (cross-platform SwiftUI)
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white)
                    }
                    Spacer()
                    Text(title).foregroundStyle(.white.opacity(0.9)).font(.headline)
                    Spacer()
                    // spacer for symmetry
                    Image(systemName: "xmark.circle.fill").opacity(0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Spacer(minLength: 0)

                if let image = Image(fromData: imageData, maxDimension: maxDisplayDimension() * 2) {
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnifyGesture)
                        .gesture(dragGesture)
                        .onTapGesture(count: 2, perform: toggleZoom)
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: scale)
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: offset)
                        .accessibilityLabel(Text(String(format: AppLocalization.localized("photo_preview.accessibility_fmt", value: "%@ photo preview"), title)))
                        .accessibilityHint(Text(AppLocalization.localized("photo_preview.zoom_hint", value: "Pinch with two fingers to zoom")))
                } else {
                    Text(AppLocalization.localized("photo_preview.unable_to_load"))
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                scale = min(max(scale * delta, 1.0), 4.0)
                lastScale = value
            }
            .onEnded { _ in
                lastScale = 1.0
                clampOffset()
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
                clampOffset()
            }
    }

    private func toggleZoom() {
        if scale > 1.1 {
            resetTransform()
        } else {
            scale = 2.0
        }
        clampOffset()
    }

    private func resetTransform() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    /// Prevent panning far outside the image bounds when zoomed.
    private func clampOffset() {
        guard scale > 1 else {
            offset = .zero
            lastOffset = .zero
            return
        }
        let maxOffset: CGFloat = 400 // generous cap; image size unknown here
        offset = CGSize(
            width: max(-maxOffset, min(maxOffset, offset.width)),
            height: max(-maxOffset, min(maxOffset, offset.height))
        )
        lastOffset = offset
    }

    private func maxDisplayDimension() -> CGFloat {
        #if os(iOS)
        return max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        #elseif os(macOS)
        return NSScreen.main?.frame.width ?? 1024
        #else
        return 1024
        #endif
    }
}
