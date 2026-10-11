import CoreGraphics
import Foundation

// MARK: - Photo location (GEO-01, GEO-02)

/// Where the coordinates or the place label of a photo come from.
enum LocationSource: String, Codable, Equatable {
    /// Measured by this iPhone at capture time.
    case device
    /// Read from the imported file's metadata.
    case exif
    /// Typed by the user. Never creates coordinates.
    case manual
    /// The project's site address. Not proof of where the photo was taken.
    case project
}

enum AccuracyAuthorizationValue: String, Codable, Equatable {
    case full
    case reduced
}

enum AddressStatus: String, Codable, Equatable {
    /// No lookup was requested.
    case none
    /// Waiting for the network lookup.
    case pending
    case resolved
    /// Lookup failed (offline or service error). Can be retried with the saved coordinates.
    case failed
    /// The service returned no address.
    case noResult
}

/// State of the location measurement for a photo taken in the app.
enum FixStatus: String, Codable, Equatable {
    /// Location was off for this photo.
    case notRequested
    /// Shutter pressed, waiting up to 10 s for a fresh measurement.
    case waiting
    case attached
    /// No fresh measurement arrived in time. The photo is saved without coordinates.
    case unavailable
}

enum AddressOverrideKind: String, Codable, Equatable {
    case manual
    case project
}

struct PhotoLocation: Codable, Equatable {
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var measuredAt: Date?
    var accuracyAuthorization: AccuracyAuthorizationValue?
    var source: LocationSource
    /// Address returned by reverse geocoding for these coordinates (kept even after a manual edit).
    var addressOriginal: String?
    var addressResolvedAt: Date?
    /// Manual label or project address shown instead of the automatic address.
    var addressOverride: String?
    var addressOverrideKind: AddressOverrideKind?
    var addressOverrideUpdatedAt: Date?
    var addressStatus: AddressStatus = .none
    var fixStatus: FixStatus = .notRequested

    init(source: LocationSource) {
        self.source = source
    }

    var hasCoordinates: Bool { latitude != nil && longitude != nil }

    /// Reduced accuracy or worse than 100 m: never presented as a precise address.
    var isApproximate: Bool {
        guard hasCoordinates else { return false }
        if accuracyAuthorization == .reduced { return true }
        if let accuracy = horizontalAccuracy { return accuracy > LocationPolicy.preciseAccuracyLimit }
        return false
    }

    /// Decimal places of shown/exported coordinates matching the real precision (A04: no false
    /// precision). 2 decimals ≈ 1 km, 3 ≈ 100 m, 5 ≈ 1 m for a precise fix.
    var coordinateDecimals: Int {
        guard isApproximate else { return 5 }
        return (horizontalAccuracy ?? 1000) >= 1000 ? 2 : 3
    }

    var displayAddress: String? {
        if let override = addressOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return addressOriginal
    }

    enum DisplayKind: Equatable {
        case geocoded
        case manual
        case project
    }

    var displayAddressKind: DisplayKind? {
        if let override = addressOverride, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return addressOverrideKind == .project ? .project : .manual
        }
        return addressOriginal == nil ? nil : .geocoded
    }

    var isEmpty: Bool { !hasCoordinates && displayAddress == nil }
}

enum LocationPolicy {
    /// A measurement is "current" for a shot only if it is at most 30 s older than the shutter.
    static let maxAgeBeforeShutter: TimeInterval = 30
    /// After the shutter we wait at most 10 s for a measurement.
    static let waitAfterShutter: TimeInterval = 10
    /// Up to 100 m is treated as precise; worse is "Approximate".
    static let preciseAccuracyLimit: Double = 100

    enum Evaluation: Equatable {
        case precise
        case approximate
        /// Older than allowed relative to the shutter (or too far after it).
        case stale
        /// Negative accuracy = invalid measurement.
        case invalid
    }

    static func evaluate(measuredAt: Date, horizontalAccuracy: Double, reducedAccuracy: Bool, shutter: Date) -> Evaluation {
        guard horizontalAccuracy >= 0 else { return .invalid }
        let delta = measuredAt.timeIntervalSince(shutter)
        guard delta >= -maxAgeBeforeShutter, delta <= waitAfterShutter else { return .stale }
        if reducedAccuracy || horizontalAccuracy > preciseAccuracyLimit { return .approximate }
        return .precise
    }
}

// MARK: - Stamp (STAMP-01)

enum StampPreset: String, Codable, CaseIterable, Identifiable {
    case compact
    case work
    case location
    case custom

    var id: String { rawValue }

    var fields: StampFields? {
        switch self {
        case .compact: return StampFields(dateTime: true, projectName: false, address: false, coordinates: false, caption: false)
        case .work: return StampFields(dateTime: true, projectName: true, address: false, coordinates: false, caption: true)
        case .location: return StampFields(dateTime: true, projectName: false, address: true, coordinates: false, caption: false)
        case .custom: return nil
        }
    }

    static func matching(_ fields: StampFields) -> StampPreset {
        for preset in [StampPreset.compact, .work, .location] where preset.fields == fields { return preset }
        return .custom
    }
}

enum StampPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

enum StampSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// Font size relative to the short side of the image (not to screen points).
    var relativeFontSize: CGFloat {
        switch self {
        case .small: return 0.026
        case .medium: return 0.034
        case .large: return 0.044
        }
    }
}

struct StampFields: Codable, Equatable {
    var dateTime: Bool
    var projectName: Bool
    var address: Bool
    var coordinates: Bool
    var caption: Bool

    static let defaultFields = StampFields(dateTime: true, projectName: false, address: false, coordinates: false, caption: false)

    var includesLocation: Bool { address || coordinates }
    var isEmpty: Bool { !dateTime && !projectName && !address && !coordinates && !caption }
}

struct StampSettings: Codable, Equatable {
    var fields: StampFields = .defaultFields
    var position: StampPosition = .bottomRight
    var size: StampSize = .medium
    var dateStyle: DateStyleOption = .long
    var timeFormat: TimeFormatOption = .system

    static let `default` = StampSettings()

    var preset: StampPreset { StampPreset.matching(fields) }
}

/// Stamp settings frozen for one photo. Changing the default stamp never changes existing photos
/// unless the user explicitly applies it to selected photos.
struct StampSnapshot: Codable, Equatable {
    var id: UUID = UUID()
    var templateVersion: Int = StampSnapshot.currentTemplateVersion
    var settings: StampSettings
    /// Language used for labels and date formatting on the stamp.
    var formattingLanguage: AppLanguage
    /// Short caption for the stamp (≤120). Nil = derived from the caption.
    var customShortCaption: String?
    /// Provenance labels that applied when the snapshot was last updated (informational).
    var provenanceLabels: [String] = []

    static let currentTemplateVersion = 1

    init(settings: StampSettings, language: AppLanguage) {
        self.settings = settings
        self.formattingLanguage = language
    }
}

enum TextLimits {
    static let projectTitle = 80
    static let siteAddress = 200
    static let clientName = 100
    static let projectNotes = 2000
    static let caption = 500
    static let stampCaption = 120
    static let pairTitle = 80
    static let pairCaption = 500
    static let reportTitle = 120
    static let reportSummary = 2000
    static let manualAddress = 200
    static let executorName = 100
    static let contactText = 200
    static let presetTitle = 60
    static let supportMessage = 4000
}

// MARK: - Reports (PDF-01…PDF-05)

enum ReportTemplate: String, Codable, CaseIterable, Identifiable {
    case standard
    case beforeAfter

    var id: String { rawValue }
    var requiresPro: Bool { self == .beforeAfter }
}

enum PageSize: String, Codable, CaseIterable, Identifiable {
    case a4
    case letter

    var id: String { rawValue }

    /// PDF points (1/72 inch). A4 = 210×297 mm, Letter = 8.5×11 in.
    var pointSize: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.2756, height: 841.8898)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }

    /// Letter for the US, A4 elsewhere.
    static var regionDefault: PageSize {
        Locale.current.region?.identifier == "US" ? .letter : .a4
    }
}

enum ReportQuality: String, Codable, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }

    var maxPixel: Int {
        switch self {
        case .standard: return 2000
        case .compact: return 1400
        }
    }

    var jpegQuality: Double {
        switch self {
        case .standard: return 0.8
        case .compact: return 0.7
        }
    }

    /// Rough bytes per photo used only for the free-space check before generation.
    var estimatedBytesPerPhoto: Int64 {
        switch self {
        case .standard: return 700_000
        case .compact: return 350_000
        }
    }
}

struct ReportSettings: Codable, Equatable {
    var template: ReportTemplate = .standard
    var language: AppLanguage = .current
    var pageSize: PageSize = .regionDefault
    var quality: ReportQuality = .standard
    var title: String = ""
    var summary: String = ""
    var includeExecutor = true
    var includeClient = true
    var includeWorkDate = true
    /// Privacy (PDF-03): all three are off by default and independent.
    var includeProjectAddress = false
    var includePhotoLocations = false
    var includeCoordinates = false
    var timeFormat: TimeFormatOption = .system
    var dateStyle: DateStyleOption = .long
    /// Pro branding.
    var includeLogo = true
    var brandPresetID: UUID?
    /// Selected items in confirmed order.
    var selectedPhotoIDs: [UUID] = []
    var selectedPairIDs: [UUID] = []
}

/// Per-project defaults remembered for the next report.
struct ReportDefaults: Codable, Equatable {
    var template: ReportTemplate = .standard
    var language: AppLanguage = .current
    var pageSize: PageSize = .regionDefault
    var quality: ReportQuality = .standard
    var timeFormat: TimeFormatOption = .system
    var dateStyle: DateStyleOption = .long
}

enum ReportStatus: String, Codable {
    case ready
    /// PDF file was not found on launch (e.g. removed outside the app).
    case missingFile
}

// MARK: - Misc enums stored as raw strings

enum PhotoSource: String, Codable {
    case capture
    case `import`
    /// Original found on launch without a database record (e.g. app closed while saving).
    case recovered
}

enum SaveState: String, Codable {
    case saving
    case saved
    /// Deletion started; finished by reconciliation if the app was closed.
    case deleting
    /// Original file is missing on disk.
    case missingFile
}

enum PairState: String, Codable {
    case draft
    case complete
}

enum ThemePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

enum ImageFormat: String, Codable {
    case jpeg
    case heic
    case png

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .png: return "png"
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        }
    }
}

/// Coding helpers for value types stored as JSON blobs in SwiftData models.
enum JSONBlob {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
