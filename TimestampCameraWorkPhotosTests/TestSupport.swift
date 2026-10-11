import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import TimestampCameraWorkPhotos

/// Isolated database (in memory) and file store (temporary directory) for one test.
@MainActor
final class TestEnvironment {
    let base: URL
    let files: FileStore
    let container: ModelContainer
    let repository: ProjectRepository

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("wp-tests-\(UUID().uuidString)", isDirectory: true)
        files = FileStore(root: base.appendingPathComponent("data"), cachesRoot: base.appendingPathComponent("caches"),
                          tempRoot: base.appendingPathComponent("tmp"))
        try files.prepareDirectories()
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(UUID().uuidString, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: [configuration])
        // In-memory Free quota: tests never touch the app's Keychain item.
        repository = ProjectRepository(container: container, files: files, usage: UsageLedger(store: MemoryUsageStore()))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }

    /// Adds a photo backed by a real JPEG file, as the capture pipeline would.
    @discardableResult
    /// `data` replaces the generated image; `sharedPath` makes the record point at an existing file
    /// (performance tests only: saves disk space, decoding cost per photo stays the same).
    func addPhoto(projectID: UUID?, width: Int = 1200, height: Int = 900, caption: String = "",
                  orientation: Int = 1, source: PhotoSource = .capture, shutter: Date = Date(),
                  timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin")!, location: PhotoLocation? = nil,
                  data customData: Data? = nil, sharedPath: String? = nil) throws -> PhotoRecord {
        let id = UUID()
        let data = customData ?? TestImages.jpeg(width: width, height: height, orientation: orientation)
        let path = sharedPath ?? FileStore.originalRelativePath(photoID: id, format: .jpeg)
        if sharedPath == nil { try files.writeAtomically(data, toRelative: path) }
        let inspection = try ImageInspector.inspect(data: data)
        let record = PhotoRecord(id: id, projectID: projectID, source: source, originalPath: path, format: .jpeg,
                                 pixelWidth: inspection.pixelWidth, pixelHeight: inspection.pixelHeight,
                                 orientation: inspection.orientation, sha256: FileStore.sha256(of: data),
                                 byteSize: Int64(data.count), order: repository.nextOrder(projectID: projectID), createdAt: shutter)
        let offset = timeZone.secondsFromGMT(for: shutter)
        record.dateSourceRaw = DateSourceKind.device.rawValue
        record.captureInstant = shutter
        record.captureLocal = LocalDateTime(date: shutter, offsetSeconds: offset).iso
        record.captureOffsetSeconds = offset
        record.captureTimeZoneID = timeZone.identifier
        record.caption = caption
        record.location = location
        record.stamp = StampSnapshot(settings: .default, language: .en)
        try repository.insert(record)
        return record
    }
}

enum TestImages {
    /// JPEG with optional EXIF date/offset, GPS and orientation.
    static func jpeg(width: Int, height: Int, orientation: Int = 1, exifDate: String? = nil, exifOffset: String? = nil,
                     gps: (Double, Double)? = nil, quality: Double = 0.8) -> Data {
        encode(image(width: width, height: height), type: .jpeg, properties: properties(orientation: orientation, exifDate: exifDate,
                                                                                         exifOffset: exifOffset, gps: gps, quality: quality))
    }

    static func png(width: Int, height: Int) -> Data {
        encode(image(width: width, height: height), type: .png, properties: [:])
    }

    static func heic(width: Int, height: Int) -> Data? {
        let data = encode(image(width: width, height: height), type: .heic, properties: [:])
        return data.isEmpty ? nil : data
    }

    static func animatedGIF(frames: Int = 2) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        for index in 0..<frames {
            let frameProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
            CGImageDestinationAddImage(destination, image(width: 40, height: 40, hue: CGFloat(index) / CGFloat(frames)), frameProps as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func image(width: Int, height: Int, hue: CGFloat = 0.55) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.3 + hue * 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A marker in the top-left corner (in image coordinates) to check orientation.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - height / 5, width: width / 5, height: height / 5))
        return context.makeImage()!
    }

    /// Photo-like content (gradient + fine texture) so JPEG size and decoding cost are close to a
    /// camera file of the same pixel count. Still synthetic: real photos are measured on a device.
    static func photoLikeJPEG(width: Int, height: Int, seed: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let tileSize = 128
        var generator = SplitMix64(seed: UInt64(seed + 1))
        var bytes = [UInt8](repeating: 255, count: tileSize * tileSize * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let value = UInt8(truncatingIfNeeded: generator.next())
            bytes[index] = value
            bytes[index + 1] = value &+ 40
            bytes[index + 2] = value &+ 90
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let tile = CGImage(width: tileSize, height: tileSize, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tileSize * 4,
                           space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let shift = CGFloat(seed % 7) / 10
        let colors = [CGColor(srgbRed: 0.2 + shift, green: 0.35, blue: 0.5, alpha: 1),
                      CGColor(srgbRed: 0.9, green: 0.8 - shift, blue: 0.6, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setAlpha(0.22)
        // Scaled-up noise: texture with detail at several frequencies, like surfaces in work photos.
        context.draw(tile, in: CGRect(x: 0, y: 0, width: tileSize * 3, height: tileSize * 3), byTiling: true)
        context.setAlpha(0.12)
        context.draw(tile, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize), byTiling: true)
        return encode(context.makeImage()!, type: .jpeg,
                      properties: properties(orientation: 1, exifDate: nil, exifOffset: nil, gps: nil, quality: 0.85))
    }

    static func properties(orientation: Int, exifDate: String?, exifOffset: String?, gps: (Double, Double)?, quality: Double) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: quality]
        var exif: [CFString: Any] = [:]
        if let exifDate { exif[kCGImagePropertyExifDateTimeOriginal] = exifDate }
        if let exifOffset { exif[kCGImagePropertyExifOffsetTimeOriginal] = exifOffset }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(gps.0), kCGImagePropertyGPSLatitudeRef: gps.0 >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(gps.1), kCGImagePropertyGPSLongitudeRef: gps.1 >= 0 ? "E" : "W",
                kCGImagePropertyGPSHPositioningError: 8.0
            ] as [CFString: Any]
        }
        return properties
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }
}

extension XCTestCase {
    func XCTAssertAppError<T>(_ code: AppErrorCode, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        do {
            _ = try body()
            XCTFail("Expected \(code.rawValue)", file: file, line: line)
        } catch let error as AppError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}

/// Deterministic generator for reproducible test images.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
