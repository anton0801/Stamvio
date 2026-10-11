import SwiftUI
import XCTest
@testable import TimestampCameraWorkPhotos

/// Generates sample deliverables and measures a 200-photo report. Runs only when
/// TEST_RUNNER_SAMPLES_DIR is passed to xcodebuild (the runner sees it as SAMPLES_DIR).
@MainActor
final class DeliverablesTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SAMPLES_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SAMPLES_DIR to generate samples")
        }
        outputDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func project(_ env: TestEnvironment, title: String, photos count: Int, captions: [String]) throws -> (Project, [PhotoRecord]) {
        var draft = ProjectDraft()
        draft.title = title
        draft.siteAddress = "24 Sample Street, Springfield"
        draft.clientName = "Sample Client"
        draft.workDate = Date()
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        env.repository.preferences().executorName = "Sample Cleaning Co."
        env.repository.preferences().executorContact = "+1 555 0100"
        var photos: [PhotoRecord] = []
        for index in 0..<count {
            var location: PhotoLocation?
            if index % 3 == 0 {
                var value = PhotoLocation(source: .device)
                value.latitude = 40.7128 + Double(index) * 0.0001
                value.longitude = -74.006
                value.horizontalAccuracy = 9
                value.accuracyAuthorization = .full
                value.addressOriginal = "24 Sample Street, Springfield, USA"
                value.fixStatus = .attached
                location = value
            }
            let photo = try env.addPhoto(projectID: project.id, width: index % 2 == 0 ? 2400 : 1800, height: index % 2 == 0 ? 1800 : 2400,
                                         caption: captions.isEmpty ? "" : captions[index % captions.count],
                                         shutter: Date().addingTimeInterval(TimeInterval(-3600 + index * 60)), location: location)
            photos.append(photo)
        }
        return (project, photos)
    }

    private func build(_ snapshot: ReportSnapshot, env: TestEnvironment, name: String) throws -> (URL, Int, TimeInterval) {
        let url = outputDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let start = Date()
        let result = try ReportBuilder(snapshot: snapshot, files: env.files).build(to: url, progress: { _, _ in }, isCancelled: { false })
        XCTAssertTrue(ReportBuilder.verify(url: url, expectedPages: result.pageCount))
        return (url, result.pageCount, Date().timeIntervalSince(start))
    }

    func testGenerateSamples() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let captions = ["Kitchen before cleaning", "Kitchen completed — all surfaces degreased", "Bathroom before",
                        "Bathroom completed, grout cleaned", "Living room windows", "Balcony door frame"]
        let (project, photos) = try project(env, title: "Apartment 24 — Cleaning", photos: 6, captions: captions)
        var settings = ReportSettings()
        settings.language = .en
        settings.pageSize = .letter
        settings.selectedPhotoIDs = photos.map(\.id)
        settings.includeProjectAddress = true
        settings.includePhotoLocations = true
        settings.summary = "Deep cleaning of kitchen, bathroom and living room. All surfaces degreased and disinfected."
        let standard = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        _ = try build(standard, env: env, name: "Sample_Standard_EN_Letter_Free.pdf")

        try env.repository.createPair(projectID: project.id, before: photos[0].id, after: photos[1].id, title: "Kitchen",
                                      caption: "Degreased worktops, cleaned cabinet fronts and the extractor hood.")
        try env.repository.createPair(projectID: project.id, before: photos[2].id, after: photos[3].id, title: "Bathroom", caption: "")
        settings.template = .beforeAfter
        settings.pageSize = .a4
        settings.selectedPairIDs = env.repository.pairs(projectID: project.id).map(\.id)
        let beforeAfter = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        _ = try build(beforeAfter, env: env, name: "Sample_BeforeAfter_EN_A4_Pro.pdf")

        settings.template = .standard
        settings.language = .ru
        settings.includePhotoLocations = false
        settings.includeCoordinates = true
        let russian = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        _ = try build(russian, env: env, name: "Sample_Standard_RU_A4_Coordinates.pdf")

        // Stamped JPEG (Work preset with location) and a backup archive.
        var stampSettings = StampSettings.default
        stampSettings.fields = StampFields(dateTime: true, projectName: true, address: true, coordinates: false, caption: true)
        photos[0].stamp = StampSnapshot(settings: stampSettings, language: .en)
        let item = PhotoExportItem(photo: photos[0], projectTitle: project.displayTitle, number: 1, defaultStamp: .default)
        let jpeg = try ImageExporter.stampedJPEG(item, options: ExportOptions(includeLocation: true, maxPixel: 2560), files: env.files)
        try jpeg.write(to: outputDirectory.appendingPathComponent("Sample_Stamped.jpg"))
        let plan = try BackupService.plan(scope: .all, repository: env.repository)
        let backup = outputDirectory.appendingPathComponent("Sample_Backup.zip")
        try BackupService.writeArchive(plan, files: env.files, to: backup, progress: { _, _ in }, isCancelled: { false })
        // The sample backup is restorable into a clean install.
        let clean = try TestEnvironment()
        defer { clean.cleanup() }
        let staged = try BackupService.stage(archiveURL: backup, stagingRoot: clean.files.tempRoot, availableBytes: nil)
        XCTAssertEqual(staged.manifest.photos.count, 6)
        let summary = try BackupService.restore(staged, importCopies: [], repository: clean.repository)
        XCTAssertEqual(summary.photos, 6)
        XCTAssertEqual(summary.projects, 1)
        XCTAssertEqual(clean.repository.allReports().count, env.repository.allReports().count)
    }

    /// Section 17: a 200-photo report completes (Simulator timing; measure again on an iPhone 12).
    func testTwoHundredPhotoReportTiming() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let long = String(repeating: "Gründliche Reinigung aller Oberflächen und Fugen. ", count: 9)
        let (project, photos) = try project(env, title: "Large report", photos: 200, captions: [long, "Короткая подпись", ""])
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        settings.language = .de
        let snapshot = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        let (url, pages, duration) = try build(snapshot, env: env, name: "Perf_200_photos_DE.pdf")
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let line = String(format: "PERF 200 photos: %d pages, %.1f s, %.1f MB\n", pages, duration, Double(size) / 1_000_000)
        print(line)
        try line.write(to: outputDirectory.appendingPathComponent("perf_200_photos.txt"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(pages, 100, "At most two photos per page")
        try FileManager.default.removeItem(at: url)

        settings.quality = .compact
        let compact = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        let (compactURL, _, compactDuration) = try build(compact, env: env, name: "Perf_200_photos_DE_compact.pdf")
        let compactSize = (try compactURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let compactLine = String(format: "PERF 200 photos compact: %.1f s, %.1f MB\n", compactDuration, Double(compactSize) / 1_000_000)
        try (line + compactLine).write(to: outputDirectory.appendingPathComponent("perf_200_photos.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: compactURL)
    }

    /// Section 17 on photo-like 12 MP files: Standard PDF of 20 photos (target ≤ 15 s on iPhone 12)
    /// and a 200-photo Pro report (must finish without memory termination). Simulator numbers are
    /// indicative only; the targets are checked on a device.
    func testTwelveMegapixelReportTiming() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var draft = ProjectDraft()
        draft.title = "12 MP report"
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        var variants: [String] = []
        var totalBytes = 0
        var photos: [PhotoRecord] = []
        for index in 0..<20 {
            try autoreleasepool {
                let landscape = index % 2 == 0
                let data = TestImages.photoLikeJPEG(width: landscape ? 4032 : 3024, height: landscape ? 3024 : 4032, seed: index)
                totalBytes += data.count
                let photo = try env.addPhoto(projectID: project.id, caption: "Photo \(index + 1)", data: data)
                variants.append(photo.originalPath)
                photos.append(photo)
            }
        }
        func addShared(upTo count: Int) throws {
            for index in photos.count..<count {
                try autoreleasepool {
                    let path = variants[index % variants.count]
                    let data = try Data(contentsOf: env.files.url(forRelative: path))
                    photos.append(try env.addPhoto(projectID: project.id, caption: "Photo \(index + 1)", data: data, sharedPath: path))
                }
            }
        }
        let averageMB = Double(totalBytes) / Double(variants.count) / 1_000_000
        let before = Self.memoryFootprintMB()

        // Free: the only project with 20 distinct photos (a larger project would be read-only in Free).
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        let free = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        let (url20, pages20, duration20) = try build(free, env: env, name: "Perf_20x12MP.pdf")
        let size20 = (try url20.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try FileManager.default.removeItem(at: url20)
        XCTAssertEqual(pages20, 10)

        try addShared(upTo: 200)
        settings.selectedPhotoIDs = photos.map(\.id)
        let pro = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        let (url200, pages200, duration200) = try build(pro, env: env, name: "Perf_200x12MP.pdf")
        let size200 = (try url200.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try FileManager.default.removeItem(at: url200)
        XCTAssertEqual(pages200, 100)
        let after = Self.memoryFootprintMB()

        let text = String(format: """
            PERF photo-like 12 MP JPEG (synthetic, avg %.1f MB per original), iOS Simulator on Mac:
            20 photos Standard (Free): %d pages, %.1f s, PDF %.1f MB
            200 photos Standard (Pro): %d pages, %.1f s, PDF %.1f MB
            (the 200-photo PDF reuses 20 distinct images; CoreGraphics stores identical images once, so its size is not representative)
            Test host memory footprint: before %.0f MB, after %.0f MB, lifetime peak %.0f MB

            """, averageMB, pages20, duration20, Double(size20) / 1_000_000, pages200, duration200, Double(size200) / 1_000_000,
            before.current, after.current, after.peak)
        print(text)
        try text.write(to: outputDirectory.appendingPathComponent("perf_12mp.txt"), atomically: true, encoding: .utf8)
    }

    private static func memoryFootprintMB() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// The drawn sample rooms as images (for the website), the same artwork the app uses.
    /// Stamped JPEGs of the drawn rooms, made by the app's own exporter, for the website.
    func testExportShowcaseStampedPhotos() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let folder = outputDirectory.appendingPathComponent("showcase")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var draft = ProjectDraft()
        draft.title = "Apartment 24 — Deep Clean"
        draft.siteAddress = "24 Linden Street"
        draft.clientName = "M. Novak"
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        var components = DateComponents(year: 2026, month: 10, day: 8, hour: 18, minute: 18)
        components.timeZone = TimeZone(identifier: "Europe/Berlin")
        let start = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        let shots: [(SampleScene.Kind, Bool, String, String, TimeInterval)] = [
            (.kitchen, false, "kitchen-before", "Kitchen before cleaning", 0),
            (.kitchen, true, "kitchen-after", "Kitchen completed", 12 * 60),
            (.bathroom, false, "bathroom-before", "Bathroom before", 20 * 60),
            (.bathroom, true, "bathroom-after", "Bathroom completed", 41 * 60),
        ]
        var stamp = StampSettings.default
        stamp.fields = StampFields(dateTime: true, projectName: true, address: true, coordinates: false, caption: true)
        for (number, shot) in shots.enumerated() {
            let renderer = ImageRenderer(content: SampleScene(kind: shot.0, clean: shot.1).frame(width: 2000, height: 1500))
            renderer.scale = 1
            let data = try XCTUnwrap(renderer.uiImage?.jpegData(compressionQuality: 0.9))
            var location = PhotoLocation(source: .device)
            location.latitude = 52.5321
            location.longitude = 13.4123
            location.horizontalAccuracy = 8
            location.accuracyAuthorization = .full
            location.addressOriginal = "24 Linden Street"
            location.fixStatus = .attached
            let photo = try env.addPhoto(projectID: project.id, caption: shot.3, shutter: start.addingTimeInterval(shot.4),
                                         location: location, data: data)
            photo.stamp = StampSnapshot(settings: stamp, language: .en)
            let item = PhotoExportItem(photo: photo, projectTitle: project.displayTitle, number: number + 1, defaultStamp: .default)
            let jpeg = try ImageExporter.stampedJPEG(item, options: ExportOptions(includeLocation: true, maxPixel: 2000), files: env.files)
            try jpeg.write(to: folder.appendingPathComponent("\(shot.2).jpg"))
        }
    }

    func testExportSampleScenes() throws {
        let folder = outputDirectory.appendingPathComponent("scenes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kinds: [(SampleScene.Kind, String)] = [(.kitchen, "kitchen"), (.bathroom, "bathroom"), (.livingRoom, "living"), (.balcony, "balcony")]
        for (kind, name) in kinds {
            for clean in [false, true] {
                let renderer = ImageRenderer(content: SampleScene(kind: kind, clean: clean).frame(width: 1200, height: 900))
                renderer.scale = 1
                let data = try XCTUnwrap(renderer.uiImage?.jpegData(compressionQuality: 0.86))
                try data.write(to: folder.appendingPathComponent("\(name)-\(clean ? "after" : "before").jpg"))
            }
        }
    }
}
