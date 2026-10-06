import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SystemOneProbeSupport

final class DecodedImageCacheTests: XCTestCase {
    private func sample(_ gray: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x:0,y:0,width:2,height:2))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
    @MainActor func testRepeatedFramesReuseDecodedImageAndChangedDataInvalidates() async throws {
        let cache = DecodedImageCache()
        let original = try sample(0.25)
        let first = try XCTUnwrap(cache.image(for: original))
        for _ in 0..<100 { XCTAssertTrue(cache.image(for: Data(original)) === first) }
        XCTAssertEqual(cache.decodeAttempts, 1)
        let replacement = try XCTUnwrap(cache.image(for: sample(0.75)))
        XCTAssertFalse(replacement === first)
        XCTAssertEqual(cache.decodeAttempts, 2)
        XCTAssertEqual(cache.cacheHits, 100)
    }
    @MainActor func testInvalidPayloadIsNotDecodedOnEveryRedraw() async {
        let cache = DecodedImageCache()
        let invalid = Data([1,2,3,4])
        XCTAssertNil(cache.image(for: invalid))
        XCTAssertNil(cache.image(for: invalid))
        XCTAssertEqual(cache.decodeAttempts, 1)
        XCTAssertEqual(cache.cacheHits, 1)
    }
}
