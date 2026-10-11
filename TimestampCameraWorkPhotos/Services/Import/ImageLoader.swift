import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Decoding with downsampling. Every preview, stamped export and PDF image goes through
/// `orientedImage` so the same EXIF orientation rules are applied everywhere (CAM-02).
enum ImageLoader {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Decodes with the orientation applied and the long side limited to `maxPixel`
    /// (never upscales). Large files are not fully decoded.
    static func orientedImage(url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return orientedImage(source: source, maxPixel: maxPixel)
    }

    static func orientedImage(data: Data, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return orientedImage(source: source, maxPixel: maxPixel)
    }

    private static func orientedImage(source: CGImageSource, maxPixel: Int?) -> CGImage? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longSide = max(width, height)
        let limit = min(maxPixel ?? longSide, longSide)
        guard limit > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// Redraws into an 8-bit sRGB bitmap with the given size (used before JPEG encoding).
    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    static func sRGBCopy(of image: CGImage) -> CGImage? {
        if image.colorSpace?.name == CGColorSpace.sRGB, image.bitsPerComponent == 8 { return image }
        guard let context = makeContext(width: image.width, height: image.height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// JPEG (sRGB) with optional metadata. Orientation is always 1 because pixels are already oriented.
    static func jpegData(_ image: CGImage, quality: Double, metadata: [CFString: Any]? = nil) -> Data? {
        guard let srgb = sRGBCopy(of: image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var properties = metadata ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, srgb, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// CGImage that keeps its JPEG bytes, so a PDF context embeds them as-is (DCT) instead of
    /// re-encoding a raw bitmap. Keeps PDF sizes predictable.
    static func jpegBackedImage(_ jpeg: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: jpeg as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Metadata of the original, for exports.
    static func properties(url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any]
    }
}

/// Grid thumbnails (≤ 480 px) cached on disk in Caches and in memory. Rebuildable at any time.
final class ThumbnailStore: @unchecked Sendable {
    static let maxPixel = 480
    private let files: FileStore
    private let memory = NSCache<NSString, UIImage>()

    init(files: FileStore) {
        self.files = files
        memory.countLimit = 400
    }

    func cached(_ photoID: UUID) -> UIImage? {
        memory.object(forKey: photoID.uuidString as NSString)
    }

    /// Loads from the disk cache or generates from the original in the background.
    func thumbnail(photoID: UUID, originalRelativePath: String) async -> UIImage? {
        if let cached = cached(photoID) { return cached }
        let files = self.files
        let image: UIImage? = await Task.detached(priority: .utility) {
            let url = files.thumbnailURL(for: photoID)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                return image
            }
            return Self.generate(photoID: photoID, originalRelativePath: originalRelativePath, files: files)
        }.value
        if let image { memory.setObject(image, forKey: photoID.uuidString as NSString) }
        return image
    }

    /// Writes the thumbnail file. Safe to call from any thread.
    @discardableResult
    static func generate(photoID: UUID, originalRelativePath: String, files: FileStore) -> UIImage? {
        guard let originalURL = try? files.url(forRelative: originalRelativePath),
              let cgImage = ImageLoader.orientedImage(url: originalURL, maxPixel: maxPixel),
              let data = ImageLoader.jpegData(cgImage, quality: 0.75) else { return nil }
        let url = files.thumbnailURL(for: photoID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return UIImage(data: data)
    }

    func invalidate(_ photoID: UUID) {
        memory.removeObject(forKey: photoID.uuidString as NSString)
        files.removeThumbnail(for: photoID)
    }

    func clearMemory() {
        memory.removeAllObjects()
    }
}
