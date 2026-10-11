import CryptoKit
import Foundation
import ZIPFoundation

enum BackupScope: Equatable {
    case all
    case project(UUID)
}

/// What will go into a backup, prepared on the main actor from a stable copy of the records.
struct BackupPlan {
    var manifest: BackupManifest
    /// Relative paths of the files to include (originals, reports, logos).
    var filePaths: [String]
    var totalBytes: Int64
    var photoCount: Int
    var archiveName: String
}

struct ProjectConflict: Identifiable, Equatable {
    var id: UUID { backupProjectID }
    let backupProjectID: UUID
    let title: String
    let existingTitle: String
}

/// A validated archive unpacked into a staging directory, ready to be restored.
struct StagedBackup {
    let manifest: BackupManifest
    let stagingDirectory: URL
}

struct RestoreSummary: Equatable {
    var projects = 0
    var photos = 0
    var reports = 0
    var pairs = 0
    var skippedProjects = 0
    var skippedPhotos = 0
}

/// DATA-03 backup and restore. Archives use ZIPFoundation (MIT, pinned 0.9.20); no custom ZIP parser.
enum BackupService {
    // MARK: Create

    @MainActor
    static func plan(scope: BackupScope, repository: ProjectRepository, now: Date = Date()) throws -> BackupPlan {
        let files = repository.files
        let projects: [Project]
        let photos: [PhotoRecord]
        switch scope {
        case .all:
            projects = repository.allProjects()
            photos = repository.allPhotosEverywhere().filter { $0.saveState == .saved }
        case .project(let id):
            guard let project = repository.project(id: id) else { throw AppError(.backupNothingToRestore) }
            projects = [project]
            photos = repository.photos(projectID: id)
        }
        let projectIDs = Set(projects.map(\.id))
        let pairs = projects.flatMap { repository.pairs(projectID: $0.id) }
        let reports = projects.flatMap { repository.reports(projectID: $0.id) }.filter { $0.status == .ready }
        let presets = scope == .all ? repository.brandPresets() : []
        let prefs = repository.preferences()

        var manifest = BackupManifest(
            createdAt: now, appVersion: AppInfo.version, appBuild: AppInfo.build,
            scope: scope == .all ? "all" : "project",
            projects: projects.map {
                .init(id: $0.id, title: $0.title, siteAddress: $0.siteAddress, clientName: $0.clientName, notes: $0.notes,
                      workDate: $0.workDate, createdAt: $0.createdAt, updatedAt: $0.updatedAt, archivedAt: $0.archivedAt,
                      reportDefaults: $0.reportDefaults, sourceProjectID: $0.sourceProjectID)
            },
            photos: photos.filter { $0.projectID == nil || projectIDs.contains($0.projectID!) }.map(photoDTO),
            pairs: pairs.map {
                .init(id: $0.id, projectID: $0.projectID, beforePhotoID: $0.beforePhotoID, afterPhotoID: $0.afterPhotoID,
                      title: $0.title, caption: $0.caption, order: $0.order, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            reports: reports.map {
                .init(id: $0.id, projectID: $0.projectID, createdAt: $0.createdAt, language: $0.languageRaw,
                      pageSize: $0.pageSizeRaw, template: $0.templateRaw, templateVersion: $0.templateVersion, title: $0.title,
                      snapshotPath: $0.snapshotPath, pdfPath: $0.pdfPath, fileName: $0.fileName, pageCount: $0.pageCount,
                      bytes: $0.bytes, photoCount: $0.photoCount, pairCount: $0.pairCount, includedPhotoIDs: $0.includedPhotoIDList)
            },
            brandPresets: presets.map {
                .init(id: $0.id, title: $0.title, executorName: $0.executorName, contactText: $0.contactText,
                      logoPath: $0.logoPath, createdAt: $0.createdAt)
            },
            profile: scope == .all ? .init(executorName: prefs.executorName, executorContact: prefs.executorContact,
                                           executorLogoPath: prefs.executorLogoPath) : nil,
            files: [])

        // Drop references to files that are missing on disk so the archive stays consistent.
        manifest.photos.removeAll { !files.fileExists(relative: $0.originalPath) }
        let keptPhotoIDs = Set(manifest.photos.map(\.id))
        for index in manifest.pairs.indices {
            if let id = manifest.pairs[index].beforePhotoID, !keptPhotoIDs.contains(id) { manifest.pairs[index].beforePhotoID = nil }
            if let id = manifest.pairs[index].afterPhotoID, !keptPhotoIDs.contains(id) { manifest.pairs[index].afterPhotoID = nil }
        }
        manifest.reports.removeAll { !files.fileExists(relative: $0.pdfPath) || !files.fileExists(relative: $0.snapshotPath) }
        for index in manifest.brandPresets.indices {
            if let logo = manifest.brandPresets[index].logoPath, !files.fileExists(relative: logo) { manifest.brandPresets[index].logoPath = nil }
        }
        if let logo = manifest.profile?.executorLogoPath, !files.fileExists(relative: logo) { manifest.profile?.executorLogoPath = nil }

        let paths = Array(Set(manifest.referencedPaths)).sorted()
        let total = paths.reduce(Int64(0)) { $0 + (files.fileSize(relative: $1) ?? 0) }
        guard total <= BackupLimits.maxTotalBytes else { throw AppError(.backupTooLarge) }

        let day = WorkDate.isoString(from: now)
        let name: String
        switch scope {
        case .all: name = "Stamvio-Backup_\(day).zip"
        case .project:
            let base = ReportNaming.fileName(projectTitle: projects.first?.title ?? "Project", date: now, reportID: UUID())
                .components(separatedBy: "_").first ?? "Project"
            name = "\(base)-Backup_\(day).zip"
        }
        return BackupPlan(manifest: manifest, filePaths: paths, totalBytes: total, photoCount: manifest.photos.count, archiveName: name)
    }

    @MainActor
    static func photoDTO(_ photo: PhotoRecord) -> BackupManifest.PhotoDTO {
        .init(id: photo.id, projectID: photo.projectID, source: photo.sourceRaw, createdAt: photo.createdAt,
              updatedAt: photo.updatedAt, importedAt: photo.importedAt, dateSource: photo.dateSourceRaw,
              captureLocal: photo.captureLocal, captureOffsetSeconds: photo.captureOffsetSeconds,
              captureTimeZoneID: photo.captureTimeZoneID, captureInstant: photo.captureInstant, captureRaw: photo.captureRaw,
              manualDateLocal: photo.manualDateLocal, manualDateOffsetSeconds: photo.manualDateOffsetSeconds,
              manualDateTimeZoneID: photo.manualDateTimeZoneID, manualDateUpdatedAt: photo.manualDateUpdatedAt,
              originalPath: photo.originalPath, format: photo.formatRaw, pixelWidth: photo.pixelWidth,
              pixelHeight: photo.pixelHeight, orientation: photo.orientation, sha256: photo.sha256,
              byteSize: photo.byteSize, caption: photo.caption, order: photo.order, location: photo.location, stamp: photo.stamp)
    }

    /// Writes the ZIP (files stored, manifest deflated and added last with all SHA-256 values).
    static func writeArchive(_ plan: BackupPlan, files: FileStore, to url: URL,
                             progress: @escaping (Int64, Int64) -> Void, isCancelled: @escaping () -> Bool) throws {
        try files.ensureSpace(for: plan.totalBytes)
        try? FileManager.default.removeItem(at: url)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create)
        } catch {
            throw AppError(.backupWriteFailed)
        }
        var manifest = plan.manifest
        var written: Int64 = 0
        do {
            for path in plan.filePaths {
                if isCancelled() { throw AppError(.reportCancelled) }
                let fileURL = try files.url(forRelative: path)
                let size = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                var hasher = SHA256()
                try archive.addEntry(with: path, type: .file, uncompressedSize: size, compressionMethod: .none,
                                     bufferSize: 256 * 1024) { position, chunkSize in
                    try handle.seek(toOffset: UInt64(position))
                    let data = try handle.read(upToCount: chunkSize) ?? Data()
                    hasher.update(data: data)
                    return data
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                manifest.files.append(.init(path: path, sha256: digest, bytes: size))
                written += size
                progress(written, plan.totalBytes)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(manifest)
            try archive.addEntry(with: BackupManifest.fileName, type: .file, uncompressedSize: Int64(json.count),
                                 compressionMethod: .deflate) { position, chunkSize in
                let start = Int(position)
                return json.subdata(in: start..<min(start + chunkSize, json.count))
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if let appError = error as? AppError { throw appError }
            throw AppError.wrap(error, default: .backupWriteFailed)
        }
    }

    // MARK: Restore

    /// Validates and unpacks into `stagingRoot/<uuid>/`. Nothing in the app is changed here.
    /// Refuses: absolute paths, "..", symlinks, unknown versions, checksum mismatches, archives over the size limit.
    static func stage(archiveURL: URL, stagingRoot: URL, availableBytes: Int64?) throws -> StagedBackup {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw AppError(.backupInvalidArchive)
        }

        var entries: [String: Entry] = [:]
        var declaredTotal: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            guard count <= BackupLimits.maxEntries else { throw AppError(.backupSizeLimit) }
            if entry.type == .symlink { throw AppError(.backupSymlink) }
            var path = entry.path
            if entry.type == .directory {
                while path.hasSuffix("/") { path.removeLast() }
                guard path.isEmpty || FileStore.isSafeRelativePath(path) else { throw AppError(.backupUnsafePath) }
                continue
            }
            guard FileStore.isSafeRelativePath(path) else { throw AppError(.backupUnsafePath) }
            guard entries[path] == nil else { throw AppError(.backupInvalidArchive) }
            declaredTotal += entry.uncompressedSize
            guard declaredTotal <= UInt64(BackupLimits.maxTotalBytes) + UInt64(BackupLimits.maxManifestBytes) else {
                throw AppError(.backupSizeLimit)
            }
            entries[path] = entry
        }

        guard let manifestEntry = entries[BackupManifest.fileName] else { throw AppError(.backupMissingManifest) }
        guard manifestEntry.uncompressedSize <= UInt64(BackupLimits.maxManifestBytes) else { throw AppError(.backupSizeLimit) }
        var manifestData = Data()
        do {
            _ = try archive.extract(manifestEntry) { chunk in
                manifestData.append(chunk)
                if Int64(manifestData.count) > BackupLimits.maxManifestBytes { throw AppError(.backupSizeLimit) }
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError(.backupInvalidArchive)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Check the version first so a newer format gets a clear message.
        struct Header: Decodable { let format: String?; let formatVersion: Int? }
        guard let header = try? decoder.decode(Header.self, from: manifestData) else { throw AppError(.backupInvalidArchive) }
        guard header.format == BackupManifest.formatName else { throw AppError(.backupInvalidArchive) }
        guard let version = header.formatVersion, version <= BackupManifest.currentVersion, version >= 1 else {
            throw AppError(.backupUnsupportedVersion)
        }
        guard let manifest = try? decoder.decode(BackupManifest.self, from: manifestData) else { throw AppError(.backupInvalidArchive) }
        try BackupManifestValidator.validate(manifest)

        if let availableBytes, availableBytes < manifest.totalBytes + FileStore.safetyMargin {
            throw AppError(.insufficientStorage)
        }

        let staging = stagingRoot.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var extractedTotal: Int64 = 0
            for file in manifest.files {
                guard let entry = entries[file.path], entry.uncompressedSize == UInt64(file.bytes) else {
                    throw AppError(.backupInvalidArchive)
                }
                let destination = staging.appendingPathComponent(file.path).standardizedFileURL
                guard destination.path.hasPrefix(staging.path + "/") else { throw AppError(.backupUnsafePath) }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let handle = try FileHandle(forWritingTo: destination)
                var hasher = SHA256()
                var bytes: Int64 = 0
                do {
                    _ = try archive.extract(entry, bufferSize: 256 * 1024) { chunk in
                        bytes += Int64(chunk.count)
                        extractedTotal += Int64(chunk.count)
                        // Never trust declared sizes: stop as soon as real data exceeds them (zip bomb).
                        if bytes > file.bytes || extractedTotal > BackupLimits.maxTotalBytes { throw AppError(.backupSizeLimit) }
                        hasher.update(data: chunk)
                        try handle.write(contentsOf: chunk)
                    }
                    try handle.close()
                } catch {
                    try? handle.close()
                    if let appError = error as? AppError { throw appError }
                    throw AppError(.backupInvalidArchive)
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard bytes == file.bytes, digest == file.sha256.lowercased() else { throw AppError(.backupChecksumMismatch) }
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return StagedBackup(manifest: manifest, stagingDirectory: staging)
    }

    /// Projects of the archive that were already imported (or originate from the same project).
    @MainActor
    static func conflicts(in manifest: BackupManifest, repository: ProjectRepository) -> [ProjectConflict] {
        let existing = repository.allProjects()
        return manifest.projects.compactMap { project in
            let lineage = project.sourceProjectID ?? project.id
            guard let match = existing.first(where: {
                $0.id == project.id || $0.sourceProjectID == project.id || $0.id == lineage || $0.sourceProjectID == lineage
            }) else { return nil }
            return ProjectConflict(backupProjectID: project.id, title: project.title, existingTitle: match.title)
        }
    }

    /// Imports a staged backup with new IDs (relations remapped). Existing projects are never overwritten.
    /// `importCopies` lists conflicting projects the user chose to import as copies; others are skipped.
    @MainActor
    static func restore(_ staged: StagedBackup, importCopies: Set<UUID>, repository: ProjectRepository) throws -> RestoreSummary {
        let manifest = staged.manifest
        let files = repository.files
        let context = repository.context
        var summary = RestoreSummary()
        let conflicting = Set(conflicts(in: manifest, repository: repository).map(\.backupProjectID))
        let existingPhotoIDs = Set(repository.allPhotosEverywhere().map(\.id))
        let unsortedHashes = Set(repository.photos(projectID: nil).map(\.sha256))

        var projectMap: [UUID: UUID] = [:]
        var photoMap: [UUID: UUID] = [:]
        var movedFiles: [String] = []
        var movedFrom: [String: String] = [:]

        /// Moves a staged file into the store under its new name. A path referenced twice is copied.
        func move(_ backupPath: String, to newPath: String) throws {
            if let first = movedFrom[backupPath] {
                try files.copyIntoStore(from: try files.url(forRelative: first), toRelative: newPath)
            } else {
                let source = staged.stagingDirectory.appendingPathComponent(backupPath)
                try files.moveIntoStore(from: source, toRelative: newPath)
                movedFrom[backupPath] = newPath
            }
            movedFiles.append(newPath)
        }

        do {
            for dto in manifest.projects {
                if conflicting.contains(dto.id) && !importCopies.contains(dto.id) {
                    summary.skippedProjects += 1
                    continue
                }
                let newID = UUID()
                projectMap[dto.id] = newID
                let title = conflicting.contains(dto.id) ? String((dto.title + " " + L("backup.copySuffix")).prefix(TextLimits.projectTitle)) : dto.title
                let project = Project(id: newID, title: title, siteAddress: dto.siteAddress, clientName: dto.clientName,
                                      notes: dto.notes, workDate: dto.workDate, createdAt: dto.createdAt)
                project.updatedAt = Date()
                project.archivedAt = dto.archivedAt
                project.reportDefaults = dto.reportDefaults ?? ReportDefaults()
                project.sourceProjectID = dto.sourceProjectID ?? dto.id
                context.insert(project)
                summary.projects += 1
            }

            for dto in manifest.photos {
                let targetProject: UUID?
                if let projectID = dto.projectID {
                    guard let mapped = projectMap[projectID] else { summary.skippedPhotos += 1; continue }
                    targetProject = mapped
                } else {
                    // Unsorted: skip photos that are already here.
                    if existingPhotoIDs.contains(dto.id) || unsortedHashes.contains(dto.sha256) { summary.skippedPhotos += 1; continue }
                    targetProject = nil
                }
                guard let format = ImageFormat(rawValue: dto.format) else { continue }
                let newID = UUID()
                let newPath = FileStore.originalRelativePath(photoID: newID, format: format)
                try move(dto.originalPath, to: newPath)
                let photo = PhotoRecord(id: newID, projectID: targetProject, source: PhotoSource(rawValue: dto.source) ?? .import,
                                        originalPath: newPath, format: format, pixelWidth: dto.pixelWidth,
                                        pixelHeight: dto.pixelHeight, orientation: dto.orientation, sha256: dto.sha256,
                                        byteSize: dto.byteSize, order: dto.order, createdAt: dto.createdAt)
                photo.updatedAt = dto.updatedAt
                photo.importedAt = dto.importedAt
                photo.dateSourceRaw = DateSourceKind(rawValue: dto.dateSource)?.rawValue ?? DateSourceKind.unavailable.rawValue
                photo.captureLocal = dto.captureLocal
                photo.captureOffsetSeconds = dto.captureOffsetSeconds
                photo.captureTimeZoneID = dto.captureTimeZoneID
                photo.captureInstant = dto.captureInstant
                photo.captureRaw = dto.captureRaw
                photo.manualDateLocal = dto.manualDateLocal
                photo.manualDateOffsetSeconds = dto.manualDateOffsetSeconds
                photo.manualDateTimeZoneID = dto.manualDateTimeZoneID
                photo.manualDateUpdatedAt = dto.manualDateUpdatedAt
                photo.caption = String(dto.caption.prefix(TextLimits.caption))
                photo.location = dto.location
                photo.stamp = dto.stamp
                if targetProject == nil { photo.order = repository.nextOrder(projectID: nil) + summary.photos }
                context.insert(photo)
                photoMap[dto.id] = newID
                summary.photos += 1
            }

            for dto in manifest.pairs {
                guard let projectID = projectMap[dto.projectID] else { continue }
                let pair = PhotoPair(projectID: projectID, beforePhotoID: dto.beforePhotoID.flatMap { photoMap[$0] },
                                     afterPhotoID: dto.afterPhotoID.flatMap { photoMap[$0] }, title: dto.title,
                                     caption: dto.caption, order: dto.order, createdAt: dto.createdAt)
                pair.updatedAt = dto.updatedAt
                context.insert(pair)
                summary.pairs += 1
            }

            for dto in manifest.reports {
                guard let projectID = projectMap[dto.projectID] else { continue }
                let newID = UUID()
                let directory = FileStore.reportDirectoryRelativePath(reportID: newID)
                let fileName = (dto.fileName as NSString).lastPathComponent
                let pdfPath = "\(directory)/\(FileStore.isSafeRelativePath(fileName) ? fileName : "report.pdf")"
                let snapshotPath = "\(directory)/snapshot.json"
                try move(dto.pdfPath, to: pdfPath)
                try move(dto.snapshotPath, to: snapshotPath)
                let report = ReportVersion(id: newID, projectID: projectID, createdAt: dto.createdAt,
                                           language: AppLanguage(rawValue: dto.language) ?? .en,
                                           pageSize: PageSize(rawValue: dto.pageSize) ?? .a4,
                                           template: ReportTemplate(rawValue: dto.template) ?? .standard,
                                           templateVersion: dto.templateVersion, title: dto.title, snapshotPath: snapshotPath,
                                           pdfPath: pdfPath, fileName: fileName, pageCount: dto.pageCount, bytes: dto.bytes,
                                           photoCount: dto.photoCount, pairCount: dto.pairCount,
                                           includedPhotoIDs: dto.includedPhotoIDs.compactMap { photoMap[$0] })
                context.insert(report)
                summary.reports += 1
            }

            for dto in manifest.brandPresets {
                var logoPath: String?
                if let logo = dto.logoPath {
                    let newPath = FileStore.logoRelativePath(id: UUID())
                    try move(logo, to: newPath)
                    logoPath = newPath
                }
                let preset = BrandPreset(title: dto.title, executorName: dto.executorName, contactText: dto.contactText,
                                         logoPath: logoPath, createdAt: dto.createdAt)
                context.insert(preset)
            }

            // The profile is filled only when the current one is empty (nothing is overwritten).
            if let profile = manifest.profile {
                let prefs = repository.preferences()
                if prefs.executorName.isEmpty && prefs.executorContact.isEmpty && prefs.executorLogoPath == nil {
                    prefs.executorName = profile.executorName
                    prefs.executorContact = profile.executorContact
                    if let logo = profile.executorLogoPath {
                        let newPath = FileStore.logoRelativePath(id: UUID())
                        try move(logo, to: newPath)
                        prefs.executorLogoPath = newPath
                    }
                }
            }
            try repository.save()
        } catch {
            context.rollback()
            for path in movedFiles { files.removeItem(relative: path) }
            try? FileManager.default.removeItem(at: staged.stagingDirectory)
            throw AppError.wrap(error, default: .backupWriteFailed)
        }
        try? FileManager.default.removeItem(at: staged.stagingDirectory)
        return summary
    }
}
