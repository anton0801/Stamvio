import Foundation

/// UI strings come from `Localizable.xcstrings` (EN/ES/RU/DE/FR) by semantic key, in the interface
/// language chosen in the app (or the iPhone's language). English is the fallback.
/// `Tools/check_localization.py` verifies that every key used here exists in all five languages.
func L(_ key: String) -> String {
    InterfaceLanguage.strings.t(key)
}

/// Formatted string; plural keys are resolved by the catalog's plural variations.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.current.formattingLocale, arguments: args)
}

/// Interface language chosen in Settings → App language. Without a choice the app follows the
/// iPhone (including the per-app language in iOS Settings). System screens — photo picker,
/// share sheet, permission prompts — always use the iPhone's language.
enum InterfaceLanguage {
    static let defaultsKey = "app.language"
    private static let lock = NSLock()
    private static var cached: LocalizedStrings?

    /// The language chosen in the app, or nil for the device language.
    static var selection: AppLanguage? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:))
    }

    static var strings: LocalizedStrings {
        let language = AppLanguage.current
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.language == language { return cached }
        let strings = LocalizedStrings(language: language)
        cached = strings
        return strings
    }
}

extension Date {
    /// Date and time in the app's interface language with the iPhone's region conventions.
    func appFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: AppLanguage.current.formattingLocale))
    }
}

/// Languages supported for the interface and for reports.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case en, es, ru, de, fr

    var id: String { rawValue }

    /// Name of the language written in that language (shown in pickers).
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .es: return "Español"
        case .ru: return "Русский"
        case .de: return "Deutsch"
        case .fr: return "Français"
        }
    }

    /// Current interface language: the one chosen in the app, otherwise the iPhone's.
    static var current: AppLanguage {
        InterfaceLanguage.selection ?? system
    }

    /// Language iOS gives the app (device language or the per-app language in iOS Settings).
    static var system: AppLanguage {
        AppLanguage(code: Bundle.main.preferredLocalizations.first ?? "en")
    }

    init(code: String) {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        self = AppLanguage(rawValue: base.lowercased()) ?? .en
    }

    /// Locale for formatting dates in this language while keeping the user's region conventions.
    var formattingLocale: Locale {
        if let region = Locale.current.region?.identifier, !region.isEmpty {
            return Locale(identifier: "\(rawValue)_\(region)")
        }
        return Locale(identifier: rawValue)
    }
}

/// Strings for a specific language, independent of the interface language.
/// Used for PDF reports and stamps so their content doesn't change when the app language changes.
struct LocalizedStrings {
    let language: AppLanguage
    let locale: Locale
    private let bundle: Bundle
    private let fallback: Bundle

    init(language: AppLanguage, bundle main: Bundle = .main) {
        self.language = language
        self.locale = language.formattingLocale
        func lproj(_ code: String) -> Bundle? {
            main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        }
        self.bundle = lproj(language.rawValue) ?? main
        self.fallback = lproj("en") ?? main
    }

    func t(_ key: String) -> String {
        let marker = "\u{1}missing\u{1}"
        let value = bundle.localizedString(forKey: key, value: marker, table: nil)
        if value != marker { return value }
        let english = fallback.localizedString(forKey: key, value: marker, table: nil)
        return english == marker ? key : english
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }
}
