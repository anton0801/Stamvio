import Foundation
import UIKit

enum SupportCategory: String, CaseIterable, Identifiable {
    case cameraImport
    case dateLocation
    case pdf
    case purchase
    case backup
    case other

    var id: String { rawValue }
    var titleKey: String { "support.category.\(rawValue)" }
}

/// Optional diagnostics, shown in full before sending (SUPPORT-01). Contains no photos, addresses,
/// GPS, project names, transaction IDs or user text.
struct Diagnostics: Equatable {
    var appVersion: String
    var build: String
    var iosVersion: String
    var deviceModel: String
    var language: String
    var category: String
    var errorCodes: [String]
    var freeSpaceRange: String

    @MainActor
    static func collect(category: SupportCategory, files: FileStore) -> Diagnostics {
        Diagnostics(appVersion: AppInfo.version, build: AppInfo.build, iosVersion: UIDevice.current.systemVersion,
                    deviceModel: modelIdentifier(), language: AppLanguage.current.rawValue, category: category.rawValue,
                    errorCodes: ErrorLog.shared.recentCodes.map(\.rawValue),
                    freeSpaceRange: freeSpaceBucket(files.availableCapacity()))
    }

    var text: String {
        [
            "App: \(appVersion) (\(build))",
            "iOS: \(iosVersion)",
            "Device: \(deviceModel)",
            "Language: \(language)",
            "Category: \(category)",
            "Recent error codes: \(errorCodes.isEmpty ? "—" : errorCodes.joined(separator: ", "))",
            "Free space: \(freeSpaceRange)"
        ].joined(separator: "\n")
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// Coarse range only.
    static func freeSpaceBucket(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown" }
        let gb = Double(bytes) / 1_000_000_000
        switch gb {
        case ..<1: return "<1 GB"
        case 1..<5: return "1–5 GB"
        case 5..<20: return "5–20 GB"
        default: return ">20 GB"
        }
    }
}

enum SupportComposer {
    static func subject(category: SupportCategory) -> String {
        "[\(AppInfo.displayName)] \(L(category.titleKey)) — \(AppInfo.version) (\(AppInfo.build))"
    }

    static func body(message: String, diagnostics: Diagnostics?) -> String {
        var body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let diagnostics {
            body += "\n\n— " + L("support.diagnostics.title") + " —\n" + diagnostics.text
        }
        return body
    }

    /// mailto: fallback when Mail is not configured. Opened only by an explicit tap.
    static func mailtoURL(email: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }
}
