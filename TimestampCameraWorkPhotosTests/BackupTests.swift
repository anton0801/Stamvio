import XCTest
@testable import TimestampCameraWorkPhotos

@MainActor
final class BackupTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: BackupTests.self)
        if let url = bundle.url(forResource: name, withExtension: "zip") ?? bundle.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures") {
            return url
        }
        throw XCTSkip("Fixture \(name) missing in test bundle")
    }

    private func populate(_ env: TestEnvironment) async throws -> (Project, [PhotoRecord]) {
        var draft = ProjectDraft()
        draft.title = "Apartment 24"
        draft.siteAddress = "1 Main St"
        draft.clientName = "Ms Client"
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        var location = PhotoLocation(source: .device)
        location.latitude = 48.8566
        location.longitude = 2.3522
        location.horizontalAccuracy = 9
        location.accuracyAuthorization = .full
        location.addressOriginal = "Paris"
        location.fixStatus = .attached
        let a = try env.addPhoto(projectID: project.id, caption: "Before cleaning", location: location)
        let b = try env.addPhoto(projectID: project.id, width: 900, height: 1200, caption: "Кухня готова")
        try env.repository.setManualDate(b, date: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "Europe/Paris")!)
        try env.repository.createPair(projectID: project.id, before: a.id, after: b.id, title: "Kitchen", caption: "Done")
        let unsorted = try env.addPhoto(projectID: nil, caption: "Quick shot")
        _ = unsorted
        try env.repository.createBrandPreset(title: "Main", executorName: "Alex Co", contactText: "+1 555", logoPath: nil)
        env.repository.preferences().executorName = "Alex"
        try env.repository.save()

        var settings = ReportSettings()
        settings.selectedPhotoIDs = [a.id, b.id]
        let job = ReportGenerationJob(snapshot: try ReportSnapshotFactory.make(project: project, settings: settings,
                                                                                repository: env.repository, isPro: false),
                                      repository: env.repository, analytics: LocalAnalyticsService())
        job.start()
        for _ in 0..<200 where job.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(env.repository.reports(projectID: project.id).count, 1)
        return (project, [a, b])
    }

    private func makeArchive(_ env: TestEnvironment, scope: BackupScope = .all) throws -> URL {
        let plan = try BackupService.plan(scope: scope, repository: env.repository)
        let url = env.files.tempRoot.appendingPathComponent(plan.archiveName)
        try BackupService.writeArchive(plan, files: env.files, to: url, progress: { _, _ in }, isCancelled: { false })
        return url
    }

    /// A22 + A23: after Pro ends, a 100-photo project stays complete: every photo is listed, the
    /// project archive ("Download your files") contains all 100 originals, originals can be exported,
    /// and the archive carries no purchase state.
    func testExpiredProProjectKeepsAllPhotosAndArchiveCarriesNoPro() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var draft = ProjectDraft()
        draft.title = "Big project"
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        for index in 0..<100 { _ = try env.addPhoto(projectID: project.id, width: 64, height: 48, caption: "Photo \(index + 1)") }
        let policy = env.repository.accessPolicy(isPro: false)
        XCTAssertEqual(policy.access(for: project.id), .readOnlyTooManyPhotos)
        let photos = env.repository.photos(projectID: project.id)
        XCTAssertEqual(photos.count, 100, "Nothing is hidden or cut to 20")

        let plan = try BackupService.plan(scope: .project(project.id), repository: env.repository)
        XCTAssertEqual(plan.photoCount, 100)
        XCTAssertEqual(plan.filePaths.filter { $0.hasPrefix("Originals/") }.count, 100)
        let item = PhotoExportItem(photo: photos[99], projectTitle: project.title, number: 100, defaultStamp: .default)
        let copy = try ImageExporter.originalCopy(item, includeLocation: false, files: env.files, directory: env.files.newTempDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

        let json = String(decoding: try JSONEncoder().encode(plan.manifest), as: UTF8.self).lowercased()
        for word in ["entitlement", "transaction", "subscription", "ispro", "workphotos.pro"] {
            XCTAssertFalse(json.contains(word), "Backup manifest must not carry purchase state: \(word)")
        }
    }

    /// A23: backup → clean install → restore. Files, captions, pairs and PDFs match; IDs are remapped.
    func testRoundTripIntoCleanInstall() async throws {
        let source = try TestEnvironment()
        defer { source.cleanup() }
        let (_, originals) = try await populate(source)
        let archive = try makeArchive(source)

        let target = try TestEnvironment()
        defer { target.cleanup() }
        let staged = try BackupService.stage(archiveURL: archive, stagingRoot: target.files.tempRoot, availableBytes: nil)
        XCTAssertTrue(BackupService.conflicts(in: staged.manifest, repository: target.repository).isEmpty)
        let summary = try BackupService.restore(staged, importCopies: [], repository: target.repository)
        XCTAssertEqual(summary.projects, 1)
        XCTAssertEqual(summary.photos, 3)
        XCTAssertEqual(summary.reports, 1)
        XCTAssertEqual(summary.pairs, 1)

        let project = try XCTUnwrap(target.repository.allProjects().first)
        XCTAssertEqual(project.title, "Apartment 24")
        XCTAssertEqual(project.clientName, "Ms Client")
        let photos = target.repository.photos(projectID: project.id)
        XCTAssertEqual(photos.map(\.caption), ["Before cleaning", "Кухня готова"])
        XCTAssertTrue(Set(photos.map(\.id)).isDisjoint(with: Set(originals.map(\.id))), "New IDs")
        for (restored, original) in zip(photos, originals) {
            XCTAssertEqual(restored.sha256, original.sha256)
            XCTAssertEqual(try FileStore.sha256(of: target.files.url(forRelative: restored.originalPath)), original.sha256)
            XCTAssertEqual(restored.captureLocal, original.captureLocal)
            XCTAssertEqual(restored.manualDateLocal, original.manualDateLocal)
        }
        XCTAssertEqual(photos[0].location?.addressOriginal, "Paris")
        XCTAssertEqual(photos[1].dateInfo.kind, .manual)

        let pair = try XCTUnwrap(target.repository.pairs(projectID: project.id).first)
        XCTAssertEqual(pair.beforePhotoID, photos[0].id)
        XCTAssertEqual(pair.afterPhotoID, photos[1].id)
        XCTAssertTrue(pair.isComplete)

        let report = try XCTUnwrap(target.repository.reports(projectID: project.id).first)
        XCTAssertEqual(report.includedPhotoIDList, photos.map(\.id), "Report links remapped")
        XCTAssertTrue(target.files.fileExists(relative: report.pdfPath))
        let sourceReport = try XCTUnwrap(source.repository.allReports().first)
        XCTAssertEqual(try FileStore.sha256(of: target.files.url(forRelative: report.pdfPath)),
                       try FileStore.sha256(of: source.files.url(forRelative: sourceReport.pdfPath)))

        XCTAssertEqual(target.repository.photos(projectID: nil).map(\.caption), ["Quick shot"])
        XCTAssertEqual(target.repository.brandPresets().map(\.title), ["Main"])
        XCTAssertEqual(target.repository.preferences().executorName, "Alex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingDirectory.path), "Staging cleaned up")
    }

    func testRepeatedRestoreAsksAndNeverOverwrites() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, _) = try await populate(env)
        let archive = try makeArchive(env, scope: .project(project.id))

        let staged = try BackupService.stage(archiveURL: archive, stagingRoot: env.files.tempRoot, availableBytes: nil)
        let conflicts = BackupService.conflicts(in: staged.manifest, repository: env.repository)
        XCTAssertEqual(conflicts.map(\.backupProjectID), [project.id])
        let skipped = try BackupService.restore(staged, importCopies: [], repository: env.repository)
        XCTAssertEqual(skipped.projects, 0)
        XCTAssertEqual(skipped.skippedProjects, 1)
        XCTAssertEqual(env.repository.allProjects().count, 1)

        let again = try BackupService.stage(archiveURL: archive, stagingRoot: env.files.tempRoot, availableBytes: nil)
        let copied = try BackupService.restore(again, importCopies: [project.id], repository: env.repository)
        XCTAssertEqual(copied.projects, 1)
        let titles = env.repository.allProjects().map(\.title).sorted()
        XCTAssertEqual(titles, ["Apartment 24", "Apartment 24 " + L("backup.copySuffix")])
        XCTAssertEqual(env.repository.photos(projectID: project.id).count, 2, "Original project untouched")

        // A restored copy is still recognised as the same lineage later.
        let third = try BackupService.stage(archiveURL: archive, stagingRoot: env.files.tempRoot, availableBytes: nil)
        XCTAssertFalse(BackupService.conflicts(in: third.manifest, repository: env.repository).isEmpty)
        try? FileManager.default.removeItem(at: third.stagingDirectory)
    }

    /// A24: damaged, unsafe or oversized archives are refused before anything changes.
    func testHostileArchivesAreRefused() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        _ = try await populate(env)
        let projectsBefore = env.repository.allProjects().count
        let photosBefore = env.repository.allPhotosEverywhere().count
        let cases: [(String, AppErrorCode)] = [
            ("backup_zip_slip", .backupUnsafePath),
            ("backup_absolute_path", .backupUnsafePath),
            ("backup_manifest_traversal", .backupUnsafePath),
            ("backup_symlink", .backupSymlink),
            ("backup_no_manifest", .backupMissingManifest),
            ("backup_future_version", .backupUnsupportedVersion),
            ("backup_bad_checksum", .backupChecksumMismatch),
            ("backup_bad_relations", .backupInvalidRelations),
            ("backup_corrupted", .backupInvalidArchive),
            ("backup_size_lie", .backupSizeLimit)
        ]
        for (name, code) in cases {
            let url = try fixture(name)
            do {
                _ = try BackupService.stage(archiveURL: url, stagingRoot: env.files.tempRoot, availableBytes: nil)
                XCTFail("\(name) was accepted")
            } catch let error as AppError {
                XCTAssertEqual(error.code, code, name)
            }
        }
        XCTAssertEqual(env.repository.allProjects().count, projectsBefore)
        XCTAssertEqual(env.repository.allPhotosEverywhere().count, photosBefore)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: env.files.tempRoot.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("restore-") }, "Staging cleaned after refusal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.files.tempRoot.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
    }

    func testValidMinimalFixtureRestores() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let staged = try BackupService.stage(archiveURL: try fixture("backup_valid_minimal"), stagingRoot: env.files.tempRoot, availableBytes: nil)
        let summary = try BackupService.restore(staged, importCopies: [], repository: env.repository)
        XCTAssertEqual(summary.projects, 1)
        XCTAssertEqual(summary.photos, 1)
        // Free: a restored single project fits the limit and becomes the Free project when persisted.
        env.repository.persistFreeSelectionIfNeeded(isPro: false)
        XCTAssertNotNil(env.repository.preferences().selectedFreeProjectID)
    }

    func testValidatorLimits() throws {
        var manifest = BackupManifest(createdAt: Date(), appVersion: "1", appBuild: "1", scope: "all", projects: [], photos: [], pairs: [],
                                      reports: [], brandPresets: [], profile: nil,
                                      files: [.init(path: "Originals/a.jpg", sha256: String(repeating: "a", count: 64),
                                                    bytes: BackupLimits.maxTotalBytes + 1)])
        XCTAssertAppError(.backupSizeLimit) { try BackupManifestValidator.validate(manifest) }
        manifest.files = [.init(path: "Database/x.store", sha256: String(repeating: "a", count: 64), bytes: 1)]
        XCTAssertAppError(.backupUnsafePath) { try BackupManifestValidator.validate(manifest) }
        manifest.files = [.init(path: "Originals/a.jpg", sha256: String(repeating: "a", count: 64), bytes: 1),
                          .init(path: "Originals/a.jpg", sha256: String(repeating: "a", count: 64), bytes: 1)]
        XCTAssertAppError(.backupInvalidArchive) { try BackupManifestValidator.validate(manifest) }
        manifest.formatVersion = 2
        XCTAssertAppError(.backupUnsupportedVersion) { try BackupManifestValidator.validate(manifest) }
    }
}
