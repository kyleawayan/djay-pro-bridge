import AppKit
import Foundation
import ImageIO

@MainActor
public final class DecodedImageCache {
    public static let shared = DecodedImageCache()
    public private(set) var decodeAttempts = 0
    public private(set) var cacheHits = 0
    private final class Entry: NSObject {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private let entries = NSCache<NSData, Entry>()

    public init() {
        entries.countLimit = 128
        entries.totalCostLimit = 64 * 1_048_576
    }

    public func image(for data: Data) -> NSImage? {
        let key = data as NSData
        if let entry = entries.object(forKey: key) {
            cacheHits += 1
            return entry.image
        }
        decodeAttempts += 1
        guard data.count <= 8 * 1_048_576,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 8_000_000,
              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            entries.setObject(Entry(nil), forKey: key, cost: data.count)
            return nil
        }
        // Materialize the bitmap once instead of asking NSImage to lazily decode on every redraw.
        let image = NSImage(cgImage: bitmap, size: NSSize(width: width, height: height))
        entries.setObject(Entry(image), forKey: key, cost: width * height * 4 + data.count)
        return image
    }
}
