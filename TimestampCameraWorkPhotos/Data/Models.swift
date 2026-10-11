import Foundation
import SwiftData

/// Version 1 of the on-device database. Large files (originals, PDFs, logos) live on disk;
/// models keep only relative paths. Relations use explicit UUIDs (projectID, photoID) so
/// backups can remap them predictably.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Project.self, PhotoRecord.self, PhotoPair.self, ReportVersion.self, BrandPreset.self, AppPreferences.self]
    }

    @Model
    final class Project {
        @Attribute(.unique) var id: UUID
        var title: String
        var siteAddress: String
        var clientName: String
        var notes: String
        /// Day of work `yyyy-MM-dd`, no time.
        var workDate: String?
        var createdAt: Date
        var updatedAt: Date
        var archivedAt: Date?
        var reportDefaultsData: Data?
        /// ID of the project this one was restored from (duplicate detection on repeated restores).
        var sourceProjectID: UUID?

        init(id: UUID = UUID(), title: String, siteAddress: String = "", clientName: String = "", notes: String = "",
             workDate: String? = nil, createdAt: Date = Date()) {
            self.id = id
            self.title = title
            self.siteAddress = siteAddress
            self.clientName = clientName
            self.notes = notes
            self.workDate = workDate
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.archivedAt = nil
            self.reportDefaultsData = nil
            self.sourceProjectID = nil
        }
    }

    @Model
    final class PhotoRecord {
        @Attribute(.unique) var id: UUID
        /// nil = Unsorted.
        var projectID: UUID?
        var sourceRaw: String
        /// When the record was added to the app.
        var createdAt: Date
        var updatedAt: Date
        /// When an imported file was copied into the app (never used as capture time).
        var importedAt: Date?

        // Capture time (TIME-01)
        var dateSourceRaw: String
        /// Wall clock at capture `yyyy-MM-ddTHH:mm:ss`.
        var captureLocal: String?
        /// UTC offset at capture, when known.
        var captureOffsetSeconds: Int?
        /// Device time zone identifier at capture (photos taken in the app).
        var captureTimeZoneID: String?
        /// Absolute instant (in-app captures and EXIF with offset).
        var captureInstant: Date?
        /// Raw EXIF value kept unchanged, e.g. "2026:10:08 14:03:22 +02:00".
        var captureRaw: String?

        // Manual override — never rewrites the values above.
        var manualDateLocal: String?
        var manualDateOffsetSeconds: Int?
        var manualDateTimeZoneID: String?
        var manualDateUpdatedAt: Date?

        // File
        /// Relative to the app's data directory, e.g. "Originals/<id>.heic".
        var originalPath: String
        var formatRaw: String
        var pixelWidth: Int
        var pixelHeight: Int
        /// EXIF orientation 1…8 of the stored original.
        var orientation: Int
        var sha256: String
        var byteSize: Int64

        var caption: String
        var order: Int
        var saveStateRaw: String

        var locationData: Data?
        var stampData: Data?

        init(id: UUID = UUID(), projectID: UUID?, source: PhotoSource, originalPath: String, format: ImageFormat,
             pixelWidth: Int, pixelHeight: Int, orientation: Int, sha256: String, byteSize: Int64, order: Int,
             createdAt: Date = Date()) {
            self.id = id
            self.projectID = projectID
            self.sourceRaw = source.rawValue
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.importedAt = nil
            self.dateSourceRaw = DateSourceKind.unavailable.rawValue
            self.captureLocal = nil
            self.captureOffsetSeconds = nil
            self.captureTimeZoneID = nil
            self.captureInstant = nil
            self.captureRaw = nil
            self.manualDateLocal = nil
            self.manualDateOffsetSeconds = nil
            self.manualDateTimeZoneID = nil
            self.manualDateUpdatedAt = nil
            self.originalPath = originalPath
            self.formatRaw = format.rawValue
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.orientation = orientation
            self.sha256 = sha256
            self.byteSize = byteSize
            self.caption = ""
            self.order = order
            self.saveStateRaw = SaveState.saved.rawValue
            self.locationData = nil
            self.stampData = nil
        }
    }

    @Model
    final class PhotoPair {
        @Attribute(.unique) var id: UUID
        var projectID: UUID
        var beforePhotoID: UUID?
        var afterPhotoID: UUID?
        var title: String
        var caption: String
        var order: Int
        var stateRaw: String
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID = UUID(), projectID: UUID, beforePhotoID: UUID?, afterPhotoID: UUID?, title: String,
             caption: String = "", order: Int, createdAt: Date = Date()) {
            self.id = id
            self.projectID = projectID
            self.beforePhotoID = beforePhotoID
            self.afterPhotoID = afterPhotoID
            self.title = title
            self.caption = caption
            self.order = order
            self.stateRaw = (beforePhotoID != nil && afterPhotoID != nil) ? PairState.complete.rawValue : PairState.draft.rawValue
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    @Model
    final class ReportVersion {
        @Attribute(.unique) var id: UUID
        var projectID: UUID
        var createdAt: Date
        var languageRaw: String
        var pageSizeRaw: String
        var templateRaw: String
        var templateVersion: Int
        var title: String
        /// Relative paths inside the data directory.
        var snapshotPath: String
        var pdfPath: String
        var fileName: String
        var pageCount: Int
        var bytes: Int64
        var statusRaw: String
        var photoCount: Int
        var pairCount: Int
        /// Comma-separated photo IDs included in this PDF (to warn when a photo is deleted).
        var includedPhotoIDs: String

        init(id: UUID, projectID: UUID, createdAt: Date, language: AppLanguage, pageSize: PageSize,
             template: ReportTemplate, templateVersion: Int, title: String, snapshotPath: String, pdfPath: String,
             fileName: String, pageCount: Int, bytes: Int64, photoCount: Int, pairCount: Int, includedPhotoIDs: [UUID]) {
            self.id = id
            self.projectID = projectID
            self.createdAt = createdAt
            self.languageRaw = language.rawValue
            self.pageSizeRaw = pageSize.rawValue
            self.templateRaw = template.rawValue
            self.templateVersion = templateVersion
            self.title = title
            self.snapshotPath = snapshotPath
            self.pdfPath = pdfPath
            self.fileName = fileName
            self.pageCount = pageCount
            self.bytes = bytes
            self.statusRaw = ReportStatus.ready.rawValue
            self.photoCount = photoCount
            self.pairCount = pairCount
            self.includedPhotoIDs = includedPhotoIDs.map(\.uuidString).joined(separator: ",")
        }
    }

    @Model
    final class BrandPreset {
        @Attribute(.unique) var id: UUID
        var title: String
        var executorName: String
        var contactText: String
        var logoPath: String?
        var styleVersion: Int
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID = UUID(), title: String, executorName: String = "", contactText: String = "", logoPath: String? = nil,
             createdAt: Date = Date()) {
            self.id = id
            self.title = title
            self.executorName = executorName
            self.contactText = contactText
            self.logoPath = logoPath
            self.styleVersion = 1
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    /// Single row with app preferences. The Free project is identified only by `selectedFreeProjectID`.
    @Model
    final class AppPreferences {
        @Attribute(.unique) var key: String
        /// Default report language.
        var reportLanguageRaw: String
        var themeRaw: String
        var defaultStampData: Data?
        var locationEnabled: Bool
        var selectedFreeProjectID: UUID?
        var analyticsConsent: Bool
        // Executor profile (S17) — all optional.
        var executorName: String
        var executorContact: String
        var executorLogoPath: String?
        var defaultPageSizeRaw: String
        /// Camera target: nil = Unsorted.
        var cameraProjectID: UUID?

        static let singletonKey = "main"

        init() {
            self.key = Self.singletonKey
            self.reportLanguageRaw = AppLanguage.current.rawValue
            self.themeRaw = ThemePreference.system.rawValue
            self.defaultStampData = nil
            self.locationEnabled = false
            self.selectedFreeProjectID = nil
            self.analyticsConsent = false
            self.executorName = ""
            self.executorContact = ""
            self.executorLogoPath = nil
            self.defaultPageSizeRaw = PageSize.regionDefault.rawValue
            self.cameraProjectID = nil
        }
    }
}

typealias Project = SchemaV1.Project
typealias PhotoRecord = SchemaV1.PhotoRecord
typealias PhotoPair = SchemaV1.PhotoPair
typealias ReportVersion = SchemaV1.ReportVersion
typealias BrandPreset = SchemaV1.BrandPreset
typealias AppPreferences = SchemaV1.AppPreferences

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Typed accessors

extension Project {
    var isArchived: Bool { archivedAt != nil }

    var reportDefaults: ReportDefaults {
        get { JSONBlob.decode(ReportDefaults.self, from: reportDefaultsData) ?? ReportDefaults() }
        set { reportDefaultsData = JSONBlob.encode(newValue) }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("project.untitled") : trimmed
    }
}

extension PhotoRecord {
    var source: PhotoSource { PhotoSource(rawValue: sourceRaw) ?? .import }
    var dateSource: DateSourceKind { DateSourceKind(rawValue: dateSourceRaw) ?? .unavailable }
    var format: ImageFormat { ImageFormat(rawValue: formatRaw) ?? .jpeg }
    var saveState: SaveState { SaveState(rawValue: saveStateRaw) ?? .saved }

    var location: PhotoLocation? {
        get { JSONBlob.decode(PhotoLocation.self, from: locationData) }
        set { locationData = JSONBlob.encode(newValue) }
    }

    var stamp: StampSnapshot? {
        get { JSONBlob.decode(StampSnapshot.self, from: stampData) }
        set { stampData = JSONBlob.encode(newValue) }
    }

    var hasManualDate: Bool { manualDateLocal != nil }

    /// Time to show, honoring the manual override and never inventing a time zone.
    var dateInfo: PhotoDateInfo {
        if let manual = manualDateLocal, let local = LocalDateTime(iso: manual) {
            return PhotoDateInfo(kind: .manual, local: local, offsetSeconds: manualDateOffsetSeconds)
        }
        return originalDateInfo
    }

    /// Capture time from the device or the file, ignoring a manual override.
    var originalDateInfo: PhotoDateInfo {
        guard let raw = captureLocal, let local = LocalDateTime(iso: raw) else {
            return PhotoDateInfo(kind: .unavailable, local: nil, offsetSeconds: nil)
        }
        switch dateSource {
        case .device: return PhotoDateInfo(kind: .device, local: local, offsetSeconds: captureOffsetSeconds)
        case .importedWithOffset: return PhotoDateInfo(kind: .importedWithOffset, local: local, offsetSeconds: captureOffsetSeconds)
        case .importedNoOffset: return PhotoDateInfo(kind: .importedNoOffset, local: local, offsetSeconds: nil)
        case .unavailable: return PhotoDateInfo(kind: .unavailable, local: nil, offsetSeconds: nil)
        }
    }

    /// Short caption for the stamp: the custom short version or the caption if it fits.
    var stampCaption: String {
        if let custom = stamp?.customShortCaption?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return String(custom.prefix(TextLimits.stampCaption))
        }
        return StampText.shortened(caption, limit: TextLimits.stampCaption)
    }

    var isImported: Bool { source == .import || source == .recovered }
}

extension PhotoPair {
    var state: PairState { PairState(rawValue: stateRaw) ?? .draft }
    var isComplete: Bool { beforePhotoID != nil && afterPhotoID != nil }

    func refreshState() {
        stateRaw = isComplete ? PairState.complete.rawValue : PairState.draft.rawValue
    }

    func contains(_ photoID: UUID) -> Bool { beforePhotoID == photoID || afterPhotoID == photoID }
}

extension ReportVersion {
    var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .en }
    var pageSize: PageSize { PageSize(rawValue: pageSizeRaw) ?? .a4 }
    var template: ReportTemplate { ReportTemplate(rawValue: templateRaw) ?? .standard }
    var status: ReportStatus { ReportStatus(rawValue: statusRaw) ?? .ready }

    var includedPhotoIDList: [UUID] {
        includedPhotoIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    func includes(photoID: UUID) -> Bool { includedPhotoIDs.contains(photoID.uuidString) }
}

extension AppPreferences {
    var reportLanguage: AppLanguage {
        get { AppLanguage(rawValue: reportLanguageRaw) ?? .en }
        set { reportLanguageRaw = newValue.rawValue }
    }

    var theme: ThemePreference {
        get { ThemePreference(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    var defaultStamp: StampSettings {
        get { JSONBlob.decode(StampSettings.self, from: defaultStampData) ?? .default }
        set { defaultStampData = JSONBlob.encode(newValue) }
    }

    var defaultPageSize: PageSize {
        get { PageSize(rawValue: defaultPageSizeRaw) ?? .regionDefault }
        set { defaultPageSizeRaw = newValue.rawValue }
    }
}

enum StampText {
    /// Shortens at a word boundary and adds "…" so the cut is visible (never silent).
    static func shortened(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > limit else { return trimmed }
        let hardLimit = max(1, limit - 1)
        let prefix = String(trimmed.prefix(hardLimit))
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > hardLimit / 2 {
            return String(prefix[..<space]) + "…"
        }
        return prefix + "…"
    }
}
