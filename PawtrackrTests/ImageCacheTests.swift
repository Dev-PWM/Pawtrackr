import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Pawtrackr

final class ImageCacheTests: XCTestCase {

    func testMatchingImageHeadersLengthsAndFootersCannotReuseAnotherPhoto() throws {
        let red = try makePNG(red: 255, blue: 0)
        let blue = try makePNG(red: 0, blue: 255)
        let length = max(red.count, blue.count) + 32
        let redPadded = red + Data(repeating: 0, count: length - red.count)
        let bluePadded = blue + Data(repeating: 0, count: length - blue.count)
        XCTAssertEqual(redPadded.prefix(16), bluePadded.prefix(16))
        XCTAssertEqual(redPadded.suffix(16), bluePadded.suffix(16))
        XCTAssertEqual(redPadded.count, bluePadded.count)
        ImageCache.shared.clearCache()
        let first = try XCTUnwrap(ImageCache.shared.image(data: redPadded, maxDimension: 50))
        let second = try XCTUnwrap(ImageCache.shared.image(data: bluePadded, maxDimension: 50))
        XCTAssertFalse(first === second, "Distinct photos must not collide on matching metadata bytes.")
    }

    /// Creates a deterministic PNG without depending on platform drawing state.
    private func makePNG(red: UInt8, blue: UInt8) throws -> Data {
        let pixels = Data([red, 0, blue, 255, red, 0, blue, 255,
                           red, 0, blue, 255, red, 0, blue, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    
    func testDownsampleToData_ReducesSize() {
        // Create a fake large-ish red square image
        #if canImport(UIKit)
        let size = CGSize(width: 500, height: 500)
        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let data = image?.jpegData(compressionQuality: 1.0)
        #else
        let size = NSSize(width: 500, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let data = image.tiffRepresentation
        #endif
        
        guard let originalData = data else {
            XCTFail("Failed to create test image data")
            return
        }
        
        // Downsample to 100px
        let downsampledData = ImageCache.shared.downsampleToData(data: originalData, maxDimension: 100)
        
        XCTAssertNotNil(downsampledData)
        XCTAssertTrue(downsampledData!.count < originalData.count)
    }
    
    func testCache_StoresAndRetrievesImage() {
        #if canImport(UIKit)
        let size = CGSize(width: 50, height: 50)
        UIGraphicsBeginImageContext(size)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let data = image?.pngData()
        #else
        let size = NSSize(width: 50, height: 50)
        let image = NSImage(size: size)
        let data = image.tiffRepresentation
        #endif
        
        guard let testData = data else { return }
        
        let cached1 = ImageCache.shared.image(data: testData, maxDimension: 50)
        XCTAssertNotNil(cached1)
        
        let cached2 = ImageCache.shared.image(data: testData, maxDimension: 50)
        XCTAssertNotNil(cached2)
        
        // Verify it hits the same object (using the same data should hit cache)
        XCTAssertEqual(cached1, cached2)
    }
}
