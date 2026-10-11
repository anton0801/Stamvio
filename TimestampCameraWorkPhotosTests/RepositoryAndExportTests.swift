import ImageIO
import XCTest
@testable import TimestampCameraWorkPhotos

@MainActor
final class RepositoryTests: XCTestCase {
    private func project(_ env: TestEnvironment, _ title: String = "P") throws -> Project {
        var draft = ProjectDraft()
        draft.title = title
        return try env.repository.createProject(draft, makeFreeProject: true)
    }

    func testProjectValidationAndLimits() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var draft = ProjectDraft()
        draft.title = "   "
        XCTAssertAppError(.validationFailed) { try env.repository.createProject(draft, makeFreeProject: true) }
        draft.title = String(repeating: "x", count: 200)
        XCTAssertFalse(draft.isValid)
        draft.title = "Ok"
        draft.notes = String(repeating: "n", count: 3000)
        let created = try env.repository.createProject(draft, makeFreeProject: true)
        XCTAssertEqual(created.notes.count, TextLimits.projectNotes)
        XCTAssertEqual(env.repository.preferences().selectedFreeProjectID, created.id)
    }

    func testPairRules() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let p = try project(env)
        let other = try project(env, "Other")
        let a = try env.addPhoto(projectID: p.id)
        let b = try env.addPhoto(projectID: p.id)
        let c = try env.addPhoto(projectID: p.id)
        let foreign = try env.addPhoto(projectID: other.id)
        XCTAssertAppError(.pairInvalid) { try env.repository.createPair(projectID: p.id, before: a.id, after: a.id, title: "", caption: "") }
        XCTAssertAppError(.pairInvalid) { try env.repository.createPair(projectID: p.id, before: a.id, after: foreign.id, title: "", caption: "") }
        let pair = try env.repository.createPair(projectID: p.id, before: a.id, after: b.id, title: "Kitchen", caption: "")
        XCTAssertTrue(pair.isComplete)
        XCTAssertAppError(.pairInvalid) { try env.repository.createPair(projectID: p.id, before: a.id, after: c.id, title: "", caption: "") }
        let draft = try env.repository.createPair(projectID: p.id, before: c.id, after: nil, title: "Draft", caption: "")
        XCTAssertEqual(draft.state, .draft)
        // Deleting a photo turns its pair into a draft, never a complete pair with a hole.
        try env.repository.deletePhotos([b])
        XCTAssertEqual(pair.state, .draft)
        XCTAssertNil(pair.afterPhotoID)
        // Moving a photo to another project removes it from pairs.
        try env.repository.move([a], to: other.id)
        XCTAssertNil(pair.beforePhotoID)
    }

    func testDeletePhotoRemovesFilesAndOptionallyReports() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let p = try project(env)
        let photo = try env.addPhoto(projectID: p.id)
        let url = try env.files.url(forRelative: photo.originalPath)
        let report = ReportVersion(id: UUID(), projectID: p.id, createdAt: Date(), language: .en, pageSize: .a4, template: .standard,
                                   templateVersion: 1, title: "R", snapshotPath: "Reports/x/snapshot.json", pdfPath: "Reports/x/r.pdf",
                                   fileName: "r.pdf", pageCount: 1, bytes: 1, photoCount: 1, pairCount: 0, includedPhotoIDs: [photo.id])
        try env.repository.register(report)
        XCTAssertEqual(env.repository.reportsIncluding(photoIDs: [photo.id]).count, 1)
        try env.repository.deletePhotos([photo], alsoDeleteReports: env.repository.reportsIncluding(photoIDs: [photo.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(env.repository.reports(projectID: p.id).isEmpty)
        XCTAssertEqual(env.repository.photoCount(projectID: p.id), 0)
    }

    func testDeleteProjectRemovesEverythingButNothingElse() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let p = try project(env)
        let keep = try env.addPhoto(projectID: nil)
        let a = try env.addPhoto(projectID: p.id)
        try env.repository.createPair(projectID: p.id, before: a.id, after: nil, title: "", caption: "")
        try env.repository.deleteProject(p)
        XCTAssertTrue(env.repository.allProjects().isEmpty)
        XCTAssertTrue(env.repository.pairs(projectID: p.id).isEmpty)
        XCTAssertFalse(env.files.fileExists(relative: a.originalPath))
        XCTAssertTrue(env.files.fileExists(relative: keep.originalPath))
        XCTAssertNil(env.repository.preferences().selectedFreeProjectID)
    }

    func testOrderingAndMove() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let p = try project(env)
        let photos = try (0..<4).map { _ in try env.addPhoto(projectID: p.id) }
        let reversed = Array(photos.reversed()).map(\.id)
        try env.repository.setOrder(reversed, projectID: p.id)
        XCTAssertEqual(env.repository.photos(projectID: p.id).map(\.id), reversed)
        try env.repository.move([photos[0]], to: nil)
        XCTAssertEqual(env.repository.photoCount(projectID: p.id), 3)
        XCTAssertEqual(env.repository.photos(projectID: nil).map(\.id), [photos[0].id])
    }

    /// DATA-01: interrupted operations are finished on launch; originals are never silently deleted.
    func testReconcilerFinishesAndRecovers() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let deleting = try env.addPhoto(projectID: nil)
        deleting.saveStateRaw = SaveState.deleting.rawValue
        let missing = try env.addPhoto(projectID: nil)
        try FileManager.default.removeItem(at: env.files.url(forRelative: missing.originalPath))
        try env.repository.save()
        // An original written right before a crash, without its record.
        let orphanID = UUID()
        let orphanData = TestImages.jpeg(width: 50, height: 40, exifDate: "2026:10:01 08:00:00", exifOffset: "+01:00")
        try env.files.writeAtomically(orphanData, toRelative: FileStore.originalRelativePath(photoID: orphanID, format: .jpeg))
        // Temp leftovers and an unregistered report folder.
        try Data("x".utf8).write(to: env.files.newStagingURL(fileExtension: "part"))
        try env.files.writeAtomically(Data("pdf".utf8), toRelative: "Reports/\(UUID().uuidString)/orphan.pdf")

        let report = Reconciler.run(repository: env.repository)
        XCTAssertEqual(report.finishedDeletes, 1)
        XCTAssertEqual(report.recoveredOriginals, 1)
        XCTAssertEqual(report.missingOriginals, 1)
        XCTAssertEqual(report.removedOrphanReports, 1)
        XCTAssertNil(env.repository.photo(id: deleting.id))
        XCTAssertEqual(env.repository.photo(id: missing.id)?.saveState, .missingFile)
        let recovered = try XCTUnwrap(env.repository.photo(id: orphanID))
        XCTAssertEqual(recovered.source, .recovered)
        XCTAssertNil(recovered.projectID)
        XCTAssertEqual(recovered.dateSource, .importedWithOffset)
        XCTAssertTrue(env.files.relativeFiles(in: .staging).isEmpty)
        // Missing-file photos stay visible (never hidden).
        XCTAssertTrue(env.repository.photos(projectID: nil).contains { $0.id == missing.id })
    }

    func testFileStoreRefusesUnsafePathsAndDefersLeasedDeletes() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        for path in ["../x", "/etc/passwd", "Originals/../../x", "", "a//b", "a\\b", "C:/x", "~/x"] {
            XCTAssertFalse(FileStore.isSafeRelativePath(path), path)
        }
        XCTAssertTrue(FileStore.isSafeRelativePath("Originals/abc.jpg"))
        let photo = try env.addPhoto(projectID: nil)
        let lease = env.files.lease([photo.originalPath])
        env.files.removeItem(relative: photo.originalPath)
        XCTAssertTrue(env.files.fileExists(relative: photo.originalPath), "Leased file kept while a report/backup reads it")
        env.files.endLease(lease)
        XCTAssertFalse(env.files.fileExists(relative: photo.originalPath))
    }

    func testClearCacheNeverTouchesOriginalsOrReports() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let photo = try env.addPhoto(projectID: nil)
        ThumbnailStore.generate(photoID: photo.id, originalRelativePath: photo.originalPath, files: env.files)
        try env.files.writeAtomically(Data("pdf".utf8), toRelative: "Reports/r/report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.files.thumbnailURL(for: photo.id).path))
        env.files.clearCaches()
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.files.thumbnailURL(for: photo.id).path))
        XCTAssertTrue(env.files.fileExists(relative: photo.originalPath))
        XCTAssertTrue(env.files.fileExists(relative: "Reports/r/report.pdf"))
    }

    func testDeleteAllData() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let p = try project(env)
        let photo = try env.addPhoto(projectID: p.id)
        try env.repository.deleteAllRecords()
        env.files.deleteAllUserFiles()
        XCTAssertTrue(env.repository.allProjects().isEmpty)
        XCTAssertTrue(env.repository.allPhotosEverywhere().isEmpty)
        XCTAssertFalse(env.files.fileExists(relative: photo.originalPath))
        XCTAssertNotNil(env.repository.preferences(), "Back to an empty state")
    }
}

@MainActor
final class ExportTests: XCTestCase {
    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    private func item(_ photo: PhotoRecord, fields: StampFields) -> PhotoExportItem {
        var settings = StampSettings.default
        settings.fields = fields
        photo.stamp = StampSnapshot(settings: settings, language: .en)
        return PhotoExportItem(photo: photo, projectTitle: "Apartment 24", number: 1, defaultStamp: .default)
    }

    /// A10 / STAMP-03: without location there is no GPS in EXIF; with location GPS is written.
    func testStampedJPEGLocationModes() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var location = PhotoLocation(source: .device)
        location.latitude = 40.7128
        location.longitude = -74.006
        location.horizontalAccuracy = 10
        location.addressOriginal = "1 Main St"
        let photo = try env.addPhoto(projectID: nil, width: 3000, height: 2000, location: location)
        let exportItem = item(photo, fields: StampFields(dateTime: true, projectName: false, address: true, coordinates: true, caption: false))

        let without = try ImageExporter.stampedJPEG(exportItem, options: ExportOptions(includeLocation: false, maxPixel: 2560), files: env.files)
        let withoutProps = properties(without)
        XCTAssertNil(withoutProps[kCGImagePropertyGPSDictionary])
        XCTAssertEqual((withoutProps[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual(max((withoutProps[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                           (withoutProps[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0), 2560)

        let with = try ImageExporter.stampedJPEG(exportItem, options: ExportOptions(includeLocation: true, maxPixel: nil), files: env.files)
        let gps = try XCTUnwrap(properties(with)[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitudeRef] as? String), "N")
        XCTAssertEqual((gps[kCGImagePropertyGPSLongitudeRef] as? String), "W")
        XCTAssertEqual((properties(with)[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 3000, "Original resolution, no upscaling")
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 40.7128, accuracy: 0.000001)
    }

    /// A04: an approximate position is not written into EXIF with false precision.
    func testApproximateLocationIsRoundedInEXIF() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var location = PhotoLocation(source: .device)
        location.latitude = 40.712776
        location.longitude = -74.005974
        location.horizontalAccuracy = 2000
        location.accuracyAuthorization = .reduced
        let photo = try env.addPhoto(projectID: nil, width: 1200, height: 900, location: location)
        let exportItem = item(photo, fields: StampFields(dateTime: true, projectName: false, address: false, coordinates: true, caption: false))
        let jpeg = try ImageExporter.stampedJPEG(exportItem, options: ExportOptions(includeLocation: true, maxPixel: 2560), files: env.files)
        let gps = try XCTUnwrap(properties(jpeg)[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 40.71, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? Double), 74.01, accuracy: 0.000001)
    }

    func testSmallPhotosAreNotUpscaled() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let photo = try env.addPhoto(projectID: nil, width: 800, height: 600)
        let data = try ImageExporter.stampedJPEG(item(photo, fields: .defaultFields), options: ExportOptions(includeLocation: false, maxPixel: 2560),
                                                 files: env.files)
        XCTAssertEqual((properties(data)[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 800)
    }

    /// A09: a rotated original is exported upright with orientation 1.
    func testRotatedOriginalExportsUpright() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let photo = try env.addPhoto(projectID: nil, width: 1600, height: 1200, orientation: 6)
        let data = try ImageExporter.stampedJPEG(item(photo, fields: .defaultFields), options: ExportOptions(includeLocation: false, maxPixel: nil),
                                                 files: env.files)
        let props = properties(data)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1200)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 1600)
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
    }

    func testOriginalCopyWithoutLocationStripsGPS() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let id = UUID()
        let data = TestImages.jpeg(width: 400, height: 300, gps: (48.85, 2.35))
        let path = FileStore.originalRelativePath(photoID: id, format: .jpeg)
        try env.files.writeAtomically(data, toRelative: path)
        let record = PhotoRecord(id: id, projectID: nil, source: .import, originalPath: path, format: .jpeg, pixelWidth: 400, pixelHeight: 300,
                                 orientation: 1, sha256: FileStore.sha256(of: data), byteSize: Int64(data.count), order: 0)
        try env.repository.insert(record)
        let exportItem = PhotoExportItem(photo: record, projectTitle: nil, number: 1, defaultStamp: .default)
        let directory = try env.files.newTempDirectory()
        let stripped = try ImageExporter.originalCopy(exportItem, includeLocation: false, files: env.files, directory: directory)
        XCTAssertNil(properties(try Data(contentsOf: stripped))[kCGImagePropertyGPSDictionary])
        let kept = try ImageExporter.originalCopy(exportItem, includeLocation: true, files: env.files, directory: directory)
        XCTAssertNotNil(properties(try Data(contentsOf: kept))[kCGImagePropertyGPSDictionary])
        // The private original is unchanged.
        XCTAssertEqual(try FileStore.sha256(of: env.files.url(forRelative: path)), record.sha256)
    }

    /// Worst case of all fields with maximum lengths on a 4:3 photo: the export refuses instead of cutting the stamp.
    func testStampOverflowIsAnErrorNotACutStamp() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var location = PhotoLocation(source: .device)
        location.latitude = 40.7128
        location.longitude = -74.006
        location.horizontalAccuracy = 10
        location.addressOverride = String(repeating: "Long street name and building ", count: 7).prefix(TextLimits.manualAddress).description
        location.addressOverrideKind = .manual
        let photo = try env.addPhoto(projectID: nil, width: 1200, height: 900, location: location)
        photo.caption = String(repeating: "Detailed caption ", count: 8)
        var settings = StampSettings.default
        settings.size = .large
        settings.fields = StampFields(dateTime: true, projectName: true, address: true, coordinates: true, caption: true)
        photo.stamp = StampSnapshot(settings: settings, language: .en)
        let project = String(repeating: "Project ", count: 10).prefix(TextLimits.projectTitle).description
        let exportItem = PhotoExportItem(photo: photo, projectTitle: project, number: 1, defaultStamp: .default)
        XCTAssertAppError(.stampOverflow) {
            try ImageExporter.stampedJPEG(exportItem, options: ExportOptions(includeLocation: true, maxPixel: nil), files: env.files)
        }
        // Without location the same stamp fits again.
        XCTAssertNoThrow(try ImageExporter.stampedJPEG(exportItem, options: ExportOptions(includeLocation: false, maxPixel: nil), files: env.files))
    }
}
