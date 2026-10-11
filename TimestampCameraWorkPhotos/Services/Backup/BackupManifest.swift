import Foundation

/// `manifest.json` of a backup archive (DATA-03). Versioned; unknown newer versions are refused.
struct BackupManifest: Codable, Equatable {
    static let formatName = "WorkPhotosBackup"
    static let currentVersion = 1
    static let fileName = "manifest.json"

    struct ProjectDTO: Codable, Equatable {
        var id: UUID
        var title: String
        var siteAddress: String
        var clientName: String
        var notes: String
        var workDate: String?
        var createdAt: Date
        var updatedAt: Date
        var archivedAt: Date?
        var reportDefaults: ReportDefaults?
        var sourceProjectID: UUID?
    }

    struct PhotoDTO: Codable, Equatable {
        var id: UUID
        var projectID: UUID?
        var source: String
        var createdAt: Date
        var updatedAt: Date
        var importedAt: Date?
        var dateSource: String
        var captureLocal: String?
        var captureOffsetSeconds: Int?
        var captureTimeZoneID: String?
        var captureInstant: Date?
        var captureRaw: String?
        var manualDateLocal: String?
        var manualDateOffsetSeconds: Int?
        var manualDateTimeZoneID: String?
        var manualDateUpdatedAt: Date?
        var originalPath: String
        var format: String
        var pixelWidth: Int
        var pixelHeight: Int
        var orientation: Int
        var sha256: String
        var byteSize: Int64
        var caption: String
        var order: Int
        var location: PhotoLocation?
        var stamp: StampSnapshot?
    }

    struct PairDTO: Codable, Equatable {
        var id: UUID
        var projectID: UUID
        var beforePhotoID: UUID?
        var afterPhotoID: UUID?
        var title: String
        var caption: String
        var order: Int
        var createdAt: Date
        var updatedAt: Date
    }

    struct ReportDTO: Codable, Equatable {
        var id: UUID
        var projectID: UUID
        var createdAt: Date
        var language: String
        var pageSize: String
        var template: String
        var templateVersion: Int
        var title: String
        var snapshotPath: String
        var pdfPath: String
        var fileName: String
        var pageCount: Int
        var bytes: Int64
        var photoCount: Int
        var pairCount: Int
        var includedPhotoIDs: [UUID]
    }

    struct BrandPresetDTO: Codable, Equatable {
        var id: UUID
        var title: String
        var executorName: String
        var contactText: String
        var logoPath: String?
        var createdAt: Date
    }

    struct ProfileDTO: Codable, Equatable {
        var executorName: String
        var executorContact: String
        var executorLogoPath: String?
    }

    struct FileEntry: Codable, Equatable {
        var path: String
        /// Integrity check of the archive content — not proof that a photo is authentic.
        var sha256: String
        var bytes: Int64
    }

    var format = BackupManifest.formatName
    var formatVersion = BackupManifest.currentVersion
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    /// "all" or "project".
    var scope: String
    var projects: [ProjectDTO]
    var photos: [PhotoDTO]
    var pairs: [PairDTO]
    var reports: [ReportDTO]
    var brandPresets: [BrandPresetDTO]
    var profile: ProfileDTO?
    var files: [FileEntry]

    /// Every path the records point to.
    var referencedPaths: [String] {
        var paths = photos.map(\.originalPath)
        for report in reports { paths.append(report.pdfPath); paths.append(report.snapshotPath) }
        paths.append(contentsOf: brandPresets.compactMap(\.logoPath))
        if let logo = profile?.executorLogoPath { paths.append(logo) }
        return paths
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

enum BackupLimits {
    /// Maximum unpacked size of one archive in v1.
    static let maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxEntries = 100_000
    static let maxManifestBytes: Int64 = 64 * 1024 * 1024
    static let allowedPrefixes = ["Originals/", "Reports/", "Logos/"]
}

/// Checks the manifest itself: format, version, paths and all relations (before anything is imported).
enum BackupManifestValidator {
    static func validate(_ manifest: BackupManifest) throws {
        guard manifest.format == BackupManifest.formatName else { throw AppError(.backupInvalidArchive) }
        guard manifest.formatVersion >= 1, manifest.formatVersion <= BackupManifest.currentVersion else {
            throw AppError(.backupUnsupportedVersion)
        }
        guard manifest.totalBytes <= BackupLimits.maxTotalBytes else { throw AppError(.backupSizeLimit) }

        var filePaths = Set<String>()
        for file in manifest.files {
            guard FileStore.isSafeRelativePath(file.path),
                  BackupLimits.allowedPrefixes.contains(where: { file.path.hasPrefix($0) }),
                  file.bytes >= 0, file.sha256.count == 64 else { throw AppError(.backupUnsafePath) }
            guard filePaths.insert(file.path).inserted else { throw AppError(.backupInvalidArchive) }
        }
        for path in manifest.referencedPaths where !filePaths.contains(path) {
            throw AppError(.backupInvalidRelations)
        }

        let projectIDs = Set(manifest.projects.map(\.id))
        guard projectIDs.count == manifest.projects.count else { throw AppError(.backupInvalidRelations) }
        var photoProject: [UUID: UUID?] = [:]
        for photo in manifest.photos {
            if let projectID = photo.projectID, !projectIDs.contains(projectID) { throw AppError(.backupInvalidRelations) }
            guard photoProject[photo.id] == nil else { throw AppError(.backupInvalidRelations) }
            guard ImageFormat(rawValue: photo.format) != nil else { throw AppError(.backupInvalidArchive) }
            photoProject[photo.id] = photo.projectID
        }
        var usedInPairs = Set<UUID>()
        for pair in manifest.pairs {
            guard projectIDs.contains(pair.projectID) else { throw AppError(.backupInvalidRelations) }
            if let before = pair.beforePhotoID, let after = pair.afterPhotoID, before == after { throw AppError(.backupInvalidRelations) }
            for id in [pair.beforePhotoID, pair.afterPhotoID].compactMap({ $0 }) {
                guard let owner = photoProject[id], owner == pair.projectID else { throw AppError(.backupInvalidRelations) }
                guard usedInPairs.insert(id).inserted else { throw AppError(.backupInvalidRelations) }
            }
        }
        for report in manifest.reports where !projectIDs.contains(report.projectID) {
            throw AppError(.backupInvalidRelations)
        }
    }
}
