//
//  TransformationView.swift
//  Pawtrackr
//
//  A high-impact view showing Before & After photos side-by-side.
//

import SwiftUI

struct TransformationView: View {
    let beforeData: Data?
    let afterData: Data?
    let petName: String
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let beforeData, let afterData {
                    comparisonLayout(before: beforeData, after: afterData)
                } else {
                    ContentUnavailableView(
                        AppLocalization.localized("transformation.missing_photos.title", value: "Missing Photos"),
                        systemImage: "photo.on.rectangle",
                        description: Text(AppLocalization.localized("transformation.missing_photos.message", value: "Both Before and After photos are required for a transformation view."))
                    )
                }
            }
            .padding()
            .navigationTitle(String(format: AppLocalization.localized("transformation.navigation_title_fmt", value: "%@'s Transformation"), petName))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: String(format: AppLocalization.localized("transformation.share_message_fmt", value: "Check out %@'s grooming transformation at Pawtrackr!"), petName)) {
                        Label(AppLocalization.localized("common.share", value: "Share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
    
    private func comparisonLayout(before: Data, after: Data) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                photoFrame(data: before)
                Text(AppLocalization.localized("transformation.before", value: "BEFORE"))
                    .font(.caption.bold())
                    .padding(6)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(10)
            }
            
            Divider()
            
            ZStack(alignment: .bottomLeading) {
                photoFrame(data: after)
                Text(AppLocalization.localized("transformation.after", value: "AFTER"))
                    .font(.caption.bold())
                    .padding(6)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .shadow(radius: 10)
    }
    
    // Decode through LazyImageDataImage so the bytes are downsampled and cached
    // off the main thread. Decoding a full-size UIImage/NSImage directly in
    // `body` re-runs on every render and is the classic cause of the photo
    // "load, flash, reload" glitch reported in the before/after view.
    private func photoFrame(data: Data) -> some View {
        LazyImageDataImage(data: data, maxDimension: 1024)
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipped()
    }
}
