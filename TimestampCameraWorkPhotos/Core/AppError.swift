import Foundation

/// Technical error codes. They are safe to show and to include in diagnostics:
/// they never contain photos, addresses, coordinates, names or user text.
enum AppErrorCode: String, CaseIterable, Codable {
    // Camera
    case cameraUnavailable = "CAM-001"
    case captureFailed = "CAM-002"
    case cameraInterrupted = "CAM-003"
    case captureSaveFailed = "CAM-004"
    case cameraConfigurationFailed = "CAM-005"
    // Import
    case importUnsupportedFormat = "IMP-001"
    case importFileTooLarge = "IMP-002"
    case importTooManyPixels = "IMP-003"
    case importCorrupted = "IMP-004"
    case importLoadFailed = "IMP-005"
    case importLimitReached = "IMP-006"
    case importAnimated = "IMP-007"
    // Storage / database
    case insufficientStorage = "STO-001"
    case fileWriteFailed = "STO-002"
    case fileMissing = "STO-003"
    case databaseSaveFailed = "STO-004"
    case databaseOpenFailed = "STO-005"
    case operationBusy = "STO-006"
    // Location
    case geocodingFailed = "GEO-001"
    case geocodingNoResult = "GEO-002"
    // Reports
    case reportLimitExceeded = "PDF-001"
    case reportGenerationFailed = "PDF-002"
    case reportVerificationFailed = "PDF-003"
    case reportCancelled = "PDF-004"
    case reportInterrupted = "PDF-005"
    case reportPhotoMissing = "PDF-006"
    case reportNothingSelected = "PDF-007"
    case reportProRequired = "PDF-008"
    // Backup
    case backupTooLarge = "BAK-001"
    case backupInvalidArchive = "BAK-002"
    case backupUnsupportedVersion = "BAK-003"
    case backupUnsafePath = "BAK-004"
    case backupChecksumMismatch = "BAK-005"
    case backupSizeLimit = "BAK-006"
    case backupMissingManifest = "BAK-007"
    case backupInvalidRelations = "BAK-008"
    case backupSymlink = "BAK-009"
    case backupWriteFailed = "BAK-010"
    case backupNothingToRestore = "BAK-011"
    // Purchases
    case productsUnavailable = "PAY-001"
    case purchaseFailed = "PAY-002"
    case purchaseUnverified = "PAY-003"
    case restoreFailed = "PAY-004"
    // Export
    case stampOverflow = "EXP-001"
    case exportFailed = "EXP-002"
    case photosAccessDenied = "EXP-003"
    // Projects
    case projectReadOnly = "PRJ-001"
    case projectArchived = "PRJ-002"
    case projectLimitReached = "PRJ-003"
    case photoLimitReached = "PRJ-004"
    case pairInvalid = "PRJ-005"
    case validationFailed = "PRJ-006"
    // Support
    case mailUnavailable = "SUP-001"

    /// Localization key with a human explanation.
    var messageKey: String { "error.\(rawValue)" }
}

struct AppError: LocalizedError, Identifiable, Equatable {
    let code: AppErrorCode
    /// Optional extra numbers for the message (limits, sizes) — never user content.
    var arguments: [String] = []

    var id: String { code.rawValue + arguments.joined(separator: ",") }

    init(_ code: AppErrorCode, arguments: [String] = []) {
        self.code = code
        self.arguments = arguments
    }

    var errorDescription: String? {
        let format = L(code.messageKey)
        // Never format with fewer arguments than placeholders.
        let placeholders = format.components(separatedBy: "%@").count - 1
        guard placeholders > 0 else { return format }
        var values = arguments
        while values.count < placeholders { values.append("—") }
        return String(format: format, locale: AppLanguage.current.formattingLocale, arguments: values.map { $0 as CVarArg })
    }

    /// "Message (CODE)" for alerts.
    var displayMessage: String {
        "\(errorDescription ?? code.rawValue) (\(code.rawValue))"
    }

    static func wrap(_ error: Error, default code: AppErrorCode) -> AppError {
        if let app = error as? AppError { return app }
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace {
            return AppError(.insufficientStorage)
        }
        if let posix = error as? POSIXError, posix.code == .ENOSPC {
            return AppError(.insufficientStorage)
        }
        return AppError(code)
    }
}

/// Remembers only the last technical error codes (no content) for the optional support diagnostics.
@MainActor
final class ErrorLog {
    static let shared = ErrorLog()
    private(set) var recentCodes: [AppErrorCode] = []

    func record(_ code: AppErrorCode) {
        recentCodes.append(code)
        if recentCodes.count > 10 { recentCodes.removeFirst(recentCodes.count - 10) }
    }

    func clear() { recentCodes.removeAll() }
}
