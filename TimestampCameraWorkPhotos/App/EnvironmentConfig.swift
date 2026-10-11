import Foundation

enum AppEnvironmentKind: String {
    case development
    case production
}

/// Product contacts and documents (set in Config/Shared.xcconfig, read from Info.plist).
/// Values are not hard-coded and never fall back to placeholders such as example.com.
/// The Release build fails its "Release configuration check" phase while required values are missing.
struct EnvironmentConfig: Equatable {
    let environment: AppEnvironmentKind
    let supportEmail: String?
    let privacyPolicyURL: URL?
    let termsURL: URL?
    let supportFormURL: URL?
    let appStoreID: String?

    static let current = EnvironmentConfig(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("$(") || Self.isPlaceholder(trimmed) { return nil }
            return trimmed
        }
        environment = AppEnvironmentKind(rawValue: value("WPAppEnvironment") ?? "") ?? .development
        supportEmail = value("WPSupportEmail").flatMap { Self.isValidEmail($0) ? $0 : nil }
        privacyPolicyURL = value("WPPrivacyPolicyURL").flatMap(Self.httpsURL)
        termsURL = value("WPTermsURL").flatMap(Self.httpsURL)
        supportFormURL = value("WPSupportFormURL").flatMap(Self.httpsURL)
        appStoreID = value("WPAppStoreID").flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
    }

    /// Items a Release build must have (shown in Debug builds as a warning).
    var missingReleaseItems: [String] {
        var missing: [String] = []
        if supportEmail == nil { missing.append("WP_SUPPORT_EMAIL") }
        if privacyPolicyURL == nil { missing.append("WP_PRIVACY_POLICY_URL") }
        if termsURL == nil { missing.append("WP_TERMS_URL") }
        return missing
    }

    var isReleaseReady: Bool { missingReleaseItems.isEmpty }

    var appStoreURL: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") }
    }

    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["example.com", "example.org", "example.net", "placeholder", "todo", "your-domain"].contains { lower.contains($0) }
    }

    static func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !value.contains(" ") else { return false }
        return !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}
