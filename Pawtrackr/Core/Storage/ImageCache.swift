//
//  ImageCache.swift
//  Pawtrackr
//
//  Thread-safe, lightweight in-memory image cache with downsampling.
//  Speeds up repeated decoding of Data-backed images across the app.
//

import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

#if canImport(UIKit)
import UIKit

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit

        // Clear cache on memory warning
        // We do this on the main queue to safely access UIApplication if needed,
        // but here we just need to clear the cache which is thread-safe.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCache()
        }
    }

    /// Returns a decoded, downsampled UIImage for the given data and max dimension.
    /// Thread-safe: can be called from any thread.
    func image(data: Data, maxDimension: CGFloat) -> UIImage? {
        let key = contentCacheKey(for: data, maxDimension: maxDimension) as NSString

        // Check cache first (fast lock-based read)
        lock.lock()
        let cachedImage = cache.object(forKey: key)
        lock.unlock()
        if let hit = cachedImage { return hit }

        // Decode image (can happen on any thread, outside lock)
        guard let image = downsampleForDisplay(data: data, maxDimension: maxDimension) else { return nil }

        // Store in cache
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        lock.lock()
        cache.setObject(image, forKey: key, cost: cost)
        lock.unlock()

        return image
    }

    /// Clears all cached images. Thread-safe.
    func clearCache() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }

    /// Removes a specific image from cache. Thread-safe.
    func removeImage(for data: Data, maxDimension: CGFloat) {
        let key = contentCacheKey(for: data, maxDimension: maxDimension) as NSString
        lock.lock()
        cache.removeObject(forKey: key)
        lock.unlock()
    }

    /// Keys the complete image content; matching file headers and lengths are insufficient.
    private func contentCacheKey(for data: Data, maxDimension: CGFloat) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-\(Int(maxDimension.rounded()))"
    }

    /// Decodes and downsamples image data to a smaller Data representation for storage.
    /// This method is safe to call from background threads and does not access MainActor properties.
    func downsampleToData(data: Data, maxDimension: CGFloat = 1024, compressionQuality: CGFloat = 0.7) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: compressionQuality)
    }

    /// Efficient downsampling using CGImageSource for display purposes.
    private func downsampleForDisplay(data: Data, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        // Safely determine scale without accessing UIScreen.main if on background thread.
        let scale: CGFloat = Thread.isMainThread ? UIScreen.main.scale : 2.0
        let maxPixels = max(1, Int(maxDimension * scale))

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

#elseif canImport(AppKit)
import AppKit

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
    }

    func image(data: Data, maxDimension: CGFloat) -> NSImage? {
        let key = contentCacheKey(for: data, maxDimension: maxDimension) as NSString

        lock.lock()
        let cachedImage = cache.object(forKey: key)
        lock.unlock()
        if let hit = cachedImage { return hit }

        guard let image = downsampleForDisplay(data: data, maxDimension: maxDimension) else { return nil }

        let cost = Int(image.size.width * image.size.height * 4)
        lock.lock()
        cache.setObject(image, forKey: key, cost: cost)
        lock.unlock()

        return image
    }

    func clearCache() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }

    func removeImage(for data: Data, maxDimension: CGFloat) {
        let key = contentCacheKey(for: data, maxDimension: maxDimension) as NSString
        lock.lock()
        cache.removeObject(forKey: key)
        lock.unlock()
    }

    /// Keys the complete image content; matching file headers and lengths are insufficient.
    private func contentCacheKey(for data: Data, maxDimension: CGFloat) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-\(Int(maxDimension.rounded()))"
    }

    func downsampleToData(data: Data, maxDimension: CGFloat = 1024, compressionQuality: CGFloat = 0.7) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, downsampleOptions as CFDictionary) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    private func downsampleForDisplay(data: Data, maxDimension: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        let scale: CGFloat = Thread.isMainThread ? (NSScreen.main?.backingScaleFactor ?? 2.0) : 2.0
        let maxPixels = max(1, Int(maxDimension * scale))

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, downsampleOptions as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }
}
#endif
