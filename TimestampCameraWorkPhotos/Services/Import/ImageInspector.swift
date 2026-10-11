import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Capture date read from file metadata. The raw value is kept unchanged.
struct ExifDate: Equatable {
    let raw: String
    let rawOffset: String?
    let local: LocalDateTime
    let offsetSeconds: Int?
}

struct ExifGPS: Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double?
    let timestamp: Date?
}

struct ImageInspection: Equatable {
    let format: ImageFormat
    /// Stored pixel size (before applying the orientation).
    let pixelWidth: Int
    let pixelHeight: Int
    /// EXIF orientation 1…8.
    let orientation: Int
    let exifDate: ExifDate?
    let gps: ExifGPS?

    var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }

    /// Pixel size after applying the orientation.
    var orientedSize: CGSize { ImageGeometry.orientedSize(width: pixelWidth, height: pixelHeight, orientation: orientation) }
}

/// Explicit v1 limits for one imported file (IMP-01).
enum ImportLimits {
    static let maxFileBytes: Int64 = 100 * 1024 * 1024
    static let maxPixels = 60_000_000

    /// Checks size and pixel count from the header, before any full decode.
    static func validate(fileSize: Int64, inspection: ImageInspection) throws {
        if fileSize > maxFileBytes {
            throw AppError(.importFileTooLarge, arguments: [ByteFormatting.string(maxFileBytes)])
        }
        if inspection.pixelWidth * inspection.pixelHeight > maxPixels {
            throw AppError(.importTooManyPixels, arguments: [String(format: "%.0f", inspection.megapixels), "60"])
        }
    }
}

enum ImageGeometry {
    static func orientedSize(width: Int, height: Int, orientation: Int) -> CGSize {
        (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}

/// Reads type, size and metadata with ImageIO without decoding the full image.
enum ImageInspector {
    static func inspect(url: URL) throws -> ImageInspection {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AppError(.importCorrupted)
        }
        return try inspect(source: source)
    }

    static func inspect(data: Data) throws -> ImageInspection {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AppError(.importCorrupted)
        }
        return try inspect(source: source)
    }

    static func inspect(source: CGImageSource) throws -> ImageInspection {
        guard let typeIdentifier = CGImageSourceGetType(source) as String? else { throw AppError(.importCorrupted) }
        let type = UTType(typeIdentifier)
        let frameCount = CGImageSourceGetCount(source)

        let format: ImageFormat
        if type?.conforms(to: .rawImage) == true || typeIdentifier.contains("raw") {
            throw AppError(.importUnsupportedFormat, arguments: ["RAW"])
        } else if typeIdentifier == "public.heics" || type?.conforms(to: .gif) == true && frameCount > 1 {
            throw AppError(.importAnimated)
        } else if type?.conforms(to: .jpeg) == true {
            format = .jpeg
        } else if type?.conforms(to: .heic) == true || type?.conforms(to: .heif) == true || typeIdentifier == "public.heif" {
            format = .heic
        } else if type?.conforms(to: .png) == true {
            if frameCount > 1 { throw AppError(.importAnimated) }
            format = .png
        } else {
            let name = type?.preferredFilenameExtension?.uppercased() ?? typeIdentifier
            throw AppError(.importUnsupportedFormat, arguments: [name])
        }

        guard frameCount > 0 else { throw AppError(.importCorrupted) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw AppError(.importCorrupted)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? ((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue
            ?? 1

        return ImageInspection(format: format, pixelWidth: width, pixelHeight: height,
                               orientation: (1...8).contains(orientation) ? orientation : 1,
                               exifDate: exifDate(from: properties), gps: gps(from: properties))
    }

    /// DateTimeOriginal (or DateTimeDigitized) with its offset if present. TIFF DateTime is a
    /// modification time and is not used as capture time.
    static func exifDate(from properties: [CFString: Any]) -> ExifDate? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        let candidates: [(CFString, CFString)] = [
            (kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal),
            (kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTimeDigitized)
        ]
        for (dateKey, offsetKey) in candidates {
            guard let raw = exif[dateKey] as? String, let local = LocalDateTime(exif: raw) else { continue }
            let rawOffset = exif[offsetKey] as? String
            return ExifDate(raw: raw, rawOffset: rawOffset, local: local, offsetSeconds: UTCOffset.parse(rawOffset))
        }
        return nil
    }

    static func gps(from properties: [CFString: Any]) -> ExifGPS? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"
        let latitude = latRef == "S" ? -abs(lat) : abs(lat)
        let longitude = lonRef == "W" ? -abs(lon) : abs(lon)
        guard (-90...90).contains(latitude), (-180...180).contains(longitude), !(latitude == 0 && longitude == 0) else { return nil }
        let accuracy = (gps[kCGImagePropertyGPSHPositioningError] as? NSNumber)?.doubleValue
        var timestamp: Date?
        if let dateStamp = gps[kCGImagePropertyGPSDateStamp] as? String, let timeStamp = gps[kCGImagePropertyGPSTimeStamp] as? String,
           let local = LocalDateTime(exif: "\(dateStamp) \(timeStamp)") {
            timestamp = local.instant(offsetSeconds: 0)
        }
        return ExifGPS(latitude: latitude, longitude: longitude,
                       horizontalAccuracy: accuracy.flatMap { $0 >= 0 ? $0 : nil }, timestamp: timestamp)
    }
}
