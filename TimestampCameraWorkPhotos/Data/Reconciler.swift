import Foundation

/// Brings database and files back in sync on launch (DATA-01). A file operation and a database write
/// are not one transaction, so an interrupted save or delete is finished or rolled back here.
/// Originals that were already saved are never deleted as "extra" without checking references:
/// an original without a record is recovered into Unsorted instead.
@MainActor
enum Reconciler {
    struct Report: Equatable {
        var finishedDeletes = 0
        var recoveredOriginals = 0
        var missingOriginals = 0
        var removedOrphanReports = 0
        var missingReports = 0
        var repairedPairs = 0
    }

    @discardableResult
    static func run(repository: ProjectRepository) -> Report {
        let files = repository.files
        var report = Report()
        // Temporary files of interrupted captures/imports/exports were never confirmed to the user.
        files.clearStaging()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: files.tempRoot.path) {
            for name in names { try? FileManager.default.removeItem(at: files.tempRoot.appendingPathComponent(name)) }
        }

        let photos = repository.allPhotosEverywhere()
        var referenced = Set<String>()
        for photo in photos {
            switch photo.saveState {
            case .deleting:
                files.removeItem(relative: photo.originalPath)
                files.removeThumbnail(for: photo.id)
                repository.context.delete(photo)
                report.finishedDeletes += 1
            case .saving:
                if files.fileExists(relative: photo.originalPath) {
                    photo.saveStateRaw = SaveState.saved.rawValue
                    referenced.insert(photo.originalPath)
                } else {
                    repository.context.delete(photo)
                }
            case .saved:
                referenced.insert(photo.originalPath)
                if !files.fileExists(relative: photo.originalPath) {
                    photo.saveStateRaw = SaveState.missingFile.rawValue
                    report.missingOriginals += 1
                }
            case .missingFile:
                referenced.insert(photo.originalPath)
                if files.fileExists(relative: photo.originalPath) { photo.saveStateRaw = SaveState.saved.rawValue }
            }
        }
        try? repository.save()

        // Originals without a record: recover into Unsorted (they may be shots saved right before a crash).
        for path in files.relativeFiles(in: .originals) where !referenced.contains(path) {
            if recoverOriginal(path, repository: repository) { report.recoveredOriginals += 1 }
        }

        // Reports: a folder without a ReportVersion was never shown as ready → remove it.
        let reports = repository.allReports()
        let reportDirectories = Set(reports.map { FileStore.reportDirectoryRelativePath(reportID: $0.id) })
        for path in files.relativeFiles(in: .reports) where !reportDirectories.contains(path) {
            files.removeItem(relative: path)
            report.removedOrphanReports += 1
        }
        for version in reports {
            let exists = files.fileExists(relative: version.pdfPath)
            let status: ReportStatus = exists ? .ready : .missingFile
            if version.status != status {
                version.statusRaw = status.rawValue
                if !exists { report.missingReports += 1 }
            }
        }

        // Pairs must never point to photos that no longer exist.
        let photoIDs = Set(repository.allPhotosEverywhere().map(\.id))
        for project in repository.allProjects() {
            for pair in repository.pairs(projectID: project.id) {
                var changed = false
                if let id = pair.beforePhotoID, !photoIDs.contains(id) { pair.beforePhotoID = nil; changed = true }
                if let id = pair.afterPhotoID, !photoIDs.contains(id) { pair.afterPhotoID = nil; changed = true }
                if changed { pair.refreshState(); report.repairedPairs += 1 }
            }
        }

        // Logos not referenced by the profile or a preset (e.g. replaced logos).
        let prefs = repository.preferences()
        var logos = Set(repository.brandPresets().compactMap(\.logoPath))
        if let logo = prefs.executorLogoPath { logos.insert(logo) }
        for path in files.relativeFiles(in: .logos) where !logos.contains(path) {
            files.removeItem(relative: path)
        }
        try? repository.save()
        return report
    }

    private static func recoverOriginal(_ path: String, repository: ProjectRepository) -> Bool {
        let files = repository.files
        guard let url = try? files.url(forRelative: path), let inspection = try? ImageInspector.inspect(url: url),
              let hash = try? FileStore.sha256(of: url) else { return false }
        let name = (path as NSString).lastPathComponent
        let idString = (name as NSString).deletingPathExtension
        let id = UUID(uuidString: idString) ?? UUID()
        guard repository.photo(id: id) == nil else { return false }
        let size = files.fileSize(relative: path) ?? 0
        let record = PhotoRecord(id: id, projectID: nil, source: .recovered, originalPath: path, format: inspection.format,
                                 pixelWidth: inspection.pixelWidth, pixelHeight: inspection.pixelHeight,
                                 orientation: inspection.orientation, sha256: hash, byteSize: size,
                                 order: repository.nextOrder(projectID: nil))
        record.importedAt = Date()
        ImportSession.applyMetadata(inspection, to: record)
        record.stamp = StampSnapshot(settings: repository.preferences().defaultStamp, language: .current)
        repository.refreshProvenance(record)
        do {
            try repository.insert(record)
            return true
        } catch {
            return false
        }
    }
}
