import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import ZIPFoundation

/// Values needed to export one photo, copied from the database on the main actor.
struct PhotoExportItem {
    let id: UUID
    let originalPath: String
    let format: ImageFormat
    let input: StampInput
    let stamp: StampSettings
    let language: AppLanguage
    let number: Int
    let projectTitle: String?

    @MainActor
    init(photo: PhotoRecord, projectTitle: String?, number: Int, defaultStamp: StampSettings) {
        id = photo.id
        originalPath = photo.originalPath
        format = photo.format
        let snapshot = photo.stamp
        stamp = snapshot?.settings ?? defaultStamp
        language = snapshot?.formattingLanguage ?? .current
        input = StampInput(dateInfo: photo.dateInfo, isImported: photo.isImported, projectTitle: projectTitle,
                           location: photo.location, shortCaption: photo.stampCaption)
        self.number = number
        self.projectTitle = projectTitle
    }
}

struct ExportOptions: Equatable {
    /// "Without location" when false: no GPS in EXIF, no address/coordinates on the stamp.
    var includeLocation: Bool
    /// nil = original resolution (Pro). Free: 2560 px.
    var maxPixel: Int?
    var jpegQuality: Double = 0.85
}

/// STAMP-03 exports. Originals in the app are never modified.
enum ImageExporter {
    /// Stamped JPEG (sRGB, orientation applied, never upscaled).
    static func stampedJPEG(_ item: PhotoExportItem, options: ExportOptions, files: FileStore) throws -> Data {
        let url = try files.url(forRelative: item.originalPath)
        guard let image = ImageLoader.orientedImage(url: url, maxPixel: options.maxPixel) else { throw AppError(.fileMissing) }
        let lines = StampContentBuilder.lines(input: item.input, settings: item.stamp, language: item.language,
                                              includeLocation: options.includeLocation)
        let stamped = try StampRenderer.render(image: image, lines: lines, settings: item.stamp)
        let metadata = exportMetadata(originalURL: url, location: options.includeLocation ? item.input.location : nil)
        guard let data = ImageLoader.jpegData(stamped, quality: options.jpegQuality, metadata: metadata) else {
            throw AppError(.exportFailed)
        }
        return data
    }

    /// EXIF/TIFF from the original, orientation reset to 1, GPS only when location is included and known.
    static func exportMetadata(originalURL: URL, location: PhotoLocation?) -> [CFString: Any] {
        var metadata: [CFString: Any] = [:]
        let original = ImageLoader.properties(url: originalURL) ?? [:]
        if var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            exif.removeValue(forKey: kCGImagePropertyExifMakerNote)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let location, let rawLat = location.latitude, let rawLon = location.longitude {
            // An approximate position is not written with false precision either.
            let lat = CoordinateFormatting.rounded(rawLat, decimals: location.coordinateDecimals)
            let lon = CoordinateFormatting.rounded(rawLon, decimals: location.coordinateDecimals)
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(lat),
                kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon),
                kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"
            ]
            if let accuracy = location.horizontalAccuracy { gps[kCGImagePropertyGPSHPositioningError] = accuracy }
            metadata[kCGImagePropertyGPSDictionary] = gps
        }
        return metadata
    }

    /// Copy of the original file. Without location, GPS metadata is removed from the copy
    /// (lossless when ImageIO supports it, otherwise re-encoded at maximum quality).
    static func originalCopy(_ item: PhotoExportItem, includeLocation: Bool, files: FileStore, directory: URL) throws -> URL {
        let source = try files.url(forRelative: item.originalPath)
        let name = exportBaseName(item) + "." + item.format.fileExtension
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        if includeLocation {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource),
              let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw AppError(.exportFailed)
        }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(destinationRef, imageSource, options as CFDictionary, &error) {
            return destination
        }
        // Fallback: re-encode without GPS.
        try? FileManager.default.removeItem(at: destination)
        guard let reencode = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else { throw AppError(.exportFailed) }
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, CGImageSourceGetPrimaryImageIndex(imageSource), nil)
            as? [CFString: Any]) ?? [:]
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        CGImageDestinationAddImageFromSource(reencode, imageSource, CGImageSourceGetPrimaryImageIndex(imageSource), properties as CFDictionary)
        guard CGImageDestinationFinalize(reencode) else { throw AppError(.exportFailed) }
        return destination
    }

    static func writeStamped(_ item: PhotoExportItem, options: ExportOptions, files: FileStore, directory: URL) throws -> URL {
        let data = try stampedJPEG(item, options: options, files: files)
        let url = directory.appendingPathComponent(exportBaseName(item) + "_stamped.jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Pro: several stamped JPEGs in one ZIP.
    static func stampedZIP(_ items: [PhotoExportItem], options: ExportOptions, files: FileStore, archiveName: String,
                           progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> URL {
        let directory = try files.newTempDirectory()
        let zipURL = directory.appendingPathComponent(archiveName)
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .create)
        } catch {
            throw AppError(.exportFailed)
        }
        var usedNames = Set<String>()
        for (index, item) in items.enumerated() {
            if isCancelled() { throw AppError(.reportCancelled) }
            try autoreleasepool {
                let data = try stampedJPEG(item, options: options, files: files)
                var name = exportBaseName(item) + "_stamped.jpg"
                if usedNames.contains(name) { name = exportBaseName(item) + "_\(item.id.uuidString.prefix(4))_stamped.jpg" }
                usedNames.insert(name)
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<min(start + size, data.count))
                }
            }
            progress(index + 1, items.count)
        }
        return zipURL
    }

    /// "Project-12" or "Photo-12" — no coordinates or addresses in file names.
    static func exportBaseName(_ item: PhotoExportItem) -> String {
        let reportName = ReportNaming.fileName(projectTitle: item.projectTitle ?? "Photo", date: Date(), reportID: item.id)
        let base = reportName.components(separatedBy: "_").first ?? "Photo"
        return "\(base)-\(item.number)"
    }

    /// Saves a file to Photos with add-only permission (asked only for this action).
    static func saveToPhotos(fileURL: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw AppError(.photosAccessDenied) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: fileURL, options: nil)
            }
        } catch {
            throw AppError(.exportFailed)
        }
    }
}
