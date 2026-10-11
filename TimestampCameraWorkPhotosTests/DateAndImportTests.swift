import ImageIO
import XCTest
@testable import TimestampCameraWorkPhotos

final class DateTimeTests: XCTestCase {
    func testParsesISOAndEXIF() {
        XCTAssertEqual(LocalDateTime(iso: "2026-10-08T14:03:22")?.iso, "2026-10-08T14:03:22")
        XCTAssertEqual(LocalDateTime(exif: "2026:10:08 14:03:22")?.iso, "2026-10-08T14:03:22")
        XCTAssertEqual(LocalDateTime(exif: "2026:10:08 14:03:22.250")?.iso, "2026-10-08T14:03:22")
    }

    func testRejectsInvalidDates() {
        XCTAssertNil(LocalDateTime(exif: "0000:00:00 00:00:00"))
        XCTAssertNil(LocalDateTime(exif: "2026:02:30 10:00:00"))
        XCTAssertNil(LocalDateTime(exif: "2026:13:01 10:00:00"))
        XCTAssertNil(LocalDateTime(exif: "garbage"))
        XCTAssertNil(LocalDateTime(exif: ""))
    }

    func testOffsetParsingAndDisplay() {
        XCTAssertEqual(UTCOffset.parse("+02:00"), 7200)
        XCTAssertEqual(UTCOffset.parse("-05:30"), -19800)
        XCTAssertEqual(UTCOffset.parse("+0100"), 3600)
        XCTAssertEqual(UTCOffset.parse("Z"), 0)
        XCTAssertNil(UTCOffset.parse("02:00"))
        XCTAssertNil(UTCOffset.parse("+25:00"))
        XCTAssertNil(UTCOffset.parse(nil))
        XCTAssertEqual(UTCOffset.display(7200), "UTC+02:00")
        XCTAssertEqual(UTCOffset.display(-19800), "UTC−05:30")
    }

    func testInstantFromOffset() {
        let local = LocalDateTime(iso: "2026-10-08T14:00:00")!
        let instant = local.instant(offsetSeconds: 7200)
        XCTAssertEqual(LocalDateTime(date: instant, offsetSeconds: 0).iso, "2026-10-08T12:00:00")
    }

    /// TIME-01 / A07: changing the phone's time zone never changes a stored capture time.
    @MainActor
    func testDisplayDoesNotDependOnCurrentTimeZone() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let shutter = ISO8601DateFormatter().date(from: "2026-10-08T12:03:00Z")!
        let photo = try env.addPhoto(projectID: nil, shutter: shutter, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let formatting = DateTimeFormatting(locale: Locale(identifier: "en_US"), dateStyle: .iso, timeFormat: .h24)
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let first = formatting.dateTimeString(photo.dateInfo.local!, offsetSeconds: photo.dateInfo.offsetSeconds)
        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
        let second = formatting.dateTimeString(photo.dateInfo.local!, offsetSeconds: photo.dateInfo.offsetSeconds)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "2026-10-08, 14:03 UTC+02:00")
    }

    func testLongDateUsesMonthName() {
        let value = LocalDateTime(iso: "2026-03-04T09:05:00")!
        let en = DateTimeFormatting(locale: Locale(identifier: "en_US")).dateString(value)
        let de = DateTimeFormatting(locale: Locale(identifier: "de_DE")).dateString(value)
        let ru = DateTimeFormatting(locale: Locale(identifier: "ru_RU")).dateString(value)
        XCTAssertTrue(en.contains("Mar"), en)
        XCTAssertTrue(de.contains("März") || de.contains("Mär"), de)
        XCTAssertTrue(ru.contains("мар"), ru)
        XCTAssertFalse(en.contains("03/04"))
    }

    func testTimeFormatOverride() {
        let value = LocalDateTime(iso: "2026-03-04T21:05:00")!
        XCTAssertTrue(DateTimeFormatting(locale: Locale(identifier: "en_US"), timeFormat: .h24).timeString(value).contains("21"))
        XCTAssertTrue(DateTimeFormatting(locale: Locale(identifier: "de_DE"), timeFormat: .h12).timeString(value).contains("9"))
    }

    @MainActor
    func testManualDateKeepsOriginalValues() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let photo = try env.addPhoto(projectID: nil)
        let originalLocal = photo.captureLocal
        let originalInstant = photo.captureInstant
        try env.repository.setManualDate(photo, date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(photo.captureLocal, originalLocal)
        XCTAssertEqual(photo.captureInstant, originalInstant)
        XCTAssertEqual(photo.dateInfo.kind, .manual)
        XCTAssertEqual(photo.originalDateInfo.kind, .device)
        XCTAssertNotNil(photo.manualDateUpdatedAt)
        XCTAssertTrue(ProvenanceLabels.labels(for: photo).contains("manualDate"))
        try env.repository.clearManualDate(photo)
        XCTAssertEqual(photo.dateInfo.kind, .device)
    }

    @MainActor
    func testSortByCaptureDateNeverInventsAbsoluteOrder() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let project = try env.repository.createProject({ var d = ProjectDraft(); d.title = "Sort"; return d }(), makeFreeProject: true)
        let late = try env.addPhoto(projectID: project.id, shutter: Date(timeIntervalSince1970: 2_000_000))
        let early = try env.addPhoto(projectID: project.id, shutter: Date(timeIntervalSince1970: 1_000_000))
        let noZone = try env.addPhoto(projectID: project.id)
        noZone.dateSourceRaw = DateSourceKind.importedNoOffset.rawValue
        noZone.captureLocal = "1960-01-01T00:00:00"
        noZone.captureInstant = nil
        let noDate = try env.addPhoto(projectID: project.id)
        noDate.dateSourceRaw = DateSourceKind.unavailable.rawValue
        noDate.captureLocal = nil
        try env.repository.save()
        try env.repository.sort(projectID: project.id, mode: .captureDate)
        let order = env.repository.photos(projectID: project.id).map(\.id)
        // Absolute times first (in order), then wall-clock-only, then no date — even though 1960 is "earlier".
        XCTAssertEqual(order, [early.id, late.id, noZone.id, noDate.id])
    }
}

final class ImportMetadataTests: XCTestCase {
    func testEXIFWithOffsetBecomesAbsoluteInstant() throws {
        let data = TestImages.jpeg(width: 200, height: 100, exifDate: "2026:09:30 09:15:00", exifOffset: "+02:00")
        let inspection = try ImageInspector.inspect(data: data)
        XCTAssertEqual(inspection.exifDate?.offsetSeconds, 7200)
        XCTAssertEqual(inspection.exifDate?.local.iso, "2026-09-30T09:15:00")
    }

    @MainActor
    func testApplyMetadataSources() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        func record(from data: Data) throws -> PhotoRecord {
            let inspection = try ImageInspector.inspect(data: data)
            let record = PhotoRecord(projectID: nil, source: .import, originalPath: "Originals/x.jpg", format: inspection.format,
                                     pixelWidth: inspection.pixelWidth, pixelHeight: inspection.pixelHeight,
                                     orientation: inspection.orientation, sha256: "", byteSize: 0, order: 0)
            record.importedAt = Date()
            ImportSession.applyMetadata(inspection, to: record)
            return record
        }
        let withOffset = try record(from: TestImages.jpeg(width: 10, height: 10, exifDate: "2026:09:30 09:15:00", exifOffset: "+02:00"))
        XCTAssertEqual(withOffset.dateSource, .importedWithOffset)
        XCTAssertEqual(withOffset.captureInstant, ISO8601DateFormatter().date(from: "2026-09-30T07:15:00Z"))
        XCTAssertEqual(withOffset.captureRaw, "2026:09:30 09:15:00 +02:00")

        let noOffset = try record(from: TestImages.jpeg(width: 10, height: 10, exifDate: "2026:09:29 18:40:00"))
        XCTAssertEqual(noOffset.dateSource, .importedNoOffset)
        XCTAssertNil(noOffset.captureInstant)
        XCTAssertNil(noOffset.dateInfo.offsetSeconds)
        XCTAssertEqual(noOffset.dateInfo.kind, .importedNoOffset)

        // A06: no date → unavailable; the import time is never used as capture time; no location invented.
        let none = try record(from: TestImages.png(width: 10, height: 10))
        XCTAssertEqual(none.dateSource, .unavailable)
        XCTAssertNil(none.captureLocal)
        XCTAssertNil(none.dateInfo.local)
        XCTAssertNil(none.location)
        XCTAssertNotNil(none.importedAt)
    }

    func testEXIFGPSIsReadWithSign() throws {
        let data = TestImages.jpeg(width: 10, height: 10, gps: (-33.8688, 151.2093))
        let gps = try XCTUnwrap(ImageInspector.inspect(data: data).gps)
        XCTAssertEqual(gps.latitude, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(gps.longitude, 151.2093, accuracy: 0.0001)
        XCTAssertEqual(gps.horizontalAccuracy ?? 0, 8, accuracy: 0.01)
    }

    func testFormatsAndRejections() throws {
        XCTAssertEqual(try ImageInspector.inspect(data: TestImages.jpeg(width: 10, height: 10)).format, .jpeg)
        XCTAssertEqual(try ImageInspector.inspect(data: TestImages.png(width: 10, height: 10)).format, .png)
        if let heic = TestImages.heic(width: 64, height: 64) {
            XCTAssertEqual(try ImageInspector.inspect(data: heic).format, .heic)
        }
        XCTAssertAppError(.importAnimated) { try ImageInspector.inspect(data: TestImages.animatedGIF()) }
        XCTAssertAppError(.importUnsupportedFormat) { try ImageInspector.inspect(data: TestImages.animatedGIF(frames: 1)) }
        let truncated = TestImages.jpeg(width: 300, height: 300).prefix(200)
        XCTAssertThrowsError(try ImageInspector.inspect(data: Data(truncated)))
        XCTAssertThrowsError(try ImageInspector.inspect(data: Data("not an image".utf8)))
    }

    func testOrientationIsReadAndAppliedOnDecode() throws {
        let data = TestImages.jpeg(width: 400, height: 200, orientation: 6)
        let inspection = try ImageInspector.inspect(data: data)
        XCTAssertEqual(inspection.orientation, 6)
        XCTAssertEqual(inspection.orientedSize, CGSize(width: 200, height: 400))
        let decoded = try XCTUnwrap(ImageLoader.orientedImage(data: data, maxPixel: nil))
        XCTAssertEqual(decoded.width, 200)
        XCTAssertEqual(decoded.height, 400)
        let small = try XCTUnwrap(ImageLoader.orientedImage(data: data, maxPixel: 100))
        XCTAssertEqual(max(small.width, small.height), 100)
    }

    func testImportLimits() throws {
        let base = try ImageInspector.inspect(data: TestImages.jpeg(width: 10, height: 10))
        XCTAssertNoThrow(try ImportLimits.validate(fileSize: 1_000, inspection: base))
        XCTAssertAppError(.importFileTooLarge) { try ImportLimits.validate(fileSize: ImportLimits.maxFileBytes + 1, inspection: base) }
        let huge = ImageInspection(format: .jpeg, pixelWidth: 9000, pixelHeight: 7000, orientation: 1, exifDate: nil, gps: nil)
        XCTAssertAppError(.importTooManyPixels) { try ImportLimits.validate(fileSize: 1_000, inspection: huge) }
        let atLimit = ImageInspection(format: .jpeg, pixelWidth: 10_000, pixelHeight: 6_000, orientation: 1, exifDate: nil, gps: nil)
        XCTAssertNoThrow(try ImportLimits.validate(fileSize: 1_000, inspection: atLimit))
    }

    func testErrorMessagesAreSafeWithMissingArguments() {
        let message = AppError(.importFileTooLarge).errorDescription ?? ""
        XCTAssertFalse(message.contains("%@"))
        XCTAssertTrue(AppError(.importTooManyPixels, arguments: ["63", "60"]).displayMessage.contains("63"))
    }
}

final class LocationPolicyTests: XCTestCase {
    func testFreshnessAndAccuracy() {
        let shutter = Date()
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter.addingTimeInterval(-10), horizontalAccuracy: 12, reducedAccuracy: false, shutter: shutter), .precise)
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter.addingTimeInterval(-30), horizontalAccuracy: 100, reducedAccuracy: false, shutter: shutter), .precise)
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter.addingTimeInterval(-31), horizontalAccuracy: 12, reducedAccuracy: false, shutter: shutter), .stale)
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter, horizontalAccuracy: 101, reducedAccuracy: false, shutter: shutter), .approximate)
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter, horizontalAccuracy: 5, reducedAccuracy: true, shutter: shutter), .approximate)
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter, horizontalAccuracy: -1, reducedAccuracy: false, shutter: shutter), .invalid)
        // A05: a measurement taken well after the shutter (user moved away) is never used for that photo.
        XCTAssertEqual(LocationPolicy.evaluate(measuredAt: shutter.addingTimeInterval(60), horizontalAccuracy: 5, reducedAccuracy: false, shutter: shutter), .stale)
    }

    func testApproximateLocationIsMarked() {
        var location = PhotoLocation(source: .device)
        location.latitude = 1
        location.longitude = 2
        location.horizontalAccuracy = 1500
        location.accuracyAuthorization = .reduced
        XCTAssertTrue(location.isApproximate)
        location.accuracyAuthorization = .full
        location.horizontalAccuracy = 30
        XCTAssertFalse(location.isApproximate)
    }
}
