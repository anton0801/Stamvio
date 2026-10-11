import Foundation

/// Immutable copy of everything a report needs (PDF-04). Built on the main actor from the database,
/// then rendered in the background, so editing the project meanwhile cannot change half a report.
/// Saved next to the PDF as `snapshot.json`.
struct ReportSnapshot: Codable, Equatable {
    static let currentFormatVersion = 1
    static let templateVersion = 1

    struct ProjectInfo: Codable, Equatable {
        var id: UUID
        var title: String
        var siteAddress: String
        var clientName: String
        var workDate: String?
    }

    struct PhotoInfo: Codable, Equatable {
        var id: UUID
        var originalPath: String
        var orientedWidth: Int
        var orientedHeight: Int
        var caption: String
        var isImported: Bool
        var dateInfo: PhotoDateInfo
        var location: PhotoLocation?

        var aspectRatio: CGFloat {
            guard orientedWidth > 0, orientedHeight > 0 else { return 4.0 / 3.0 }
            return CGFloat(orientedWidth) / CGFloat(orientedHeight)
        }
    }

    struct PairInfo: Codable, Equatable {
        var id: UUID
        var title: String
        var caption: String
        var beforeID: UUID
        var afterID: UUID
    }

    struct Branding: Codable, Equatable {
        var executorName: String?
        var contactText: String?
        /// Pro only.
        var logoPath: String?
        /// Free reports carry a small "Created with …" line in the footer (never over photos).
        var showCreatedWith: Bool
    }

    var formatVersion = ReportSnapshot.currentFormatVersion
    var reportID: UUID
    var createdAt: Date
    var createdOffsetSeconds: Int
    var settings: ReportSettings
    var project: ProjectInfo
    /// Standard: the selected photos in confirmed order. Before/After: photos used by the pairs.
    var photos: [PhotoInfo]
    var pairs: [PairInfo]
    var branding: Branding
    /// Before/After preview in Free: watermarked and never registered as a report.
    var isProPreview: Bool
    var appName: String

    func photo(_ id: UUID) -> PhotoInfo? { photos.first { $0.id == id } }

    var includedPhotoIDs: [UUID] { photos.map(\.id) }
}

enum ReportNaming {
    /// `Apartment-24_2026-10-08_A7F2.pdf`: safe shortened project name + date + short ID.
    /// Never includes coordinates. The report ID keeps names unique, so nothing is overwritten.
    static func fileName(projectTitle: String, date: Date, reportID: UUID, calendar: Calendar = .current) -> String {
        var base = projectTitle.applyingTransform(.toLatin, reverse: false) ?? projectTitle
        base = base.applyingTransform(.stripDiacritics, reverse: false) ?? base
        var result = ""
        var lastWasDash = false
        for scalar in base.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.count > 40 {
            result = String(result.prefix(40))
            while result.hasSuffix("-") { result.removeLast() }
        }
        if result.isEmpty { result = "Report" }
        let day = WorkDate.isoString(from: date, calendar: calendar)
        let shortID = String(reportID.uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).uppercased()
        return "\(result)_\(day)_\(shortID).pdf"
    }
}
