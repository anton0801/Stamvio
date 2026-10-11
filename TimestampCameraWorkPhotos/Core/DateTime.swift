import Foundation

/// Wall-clock date and time without a time zone, e.g. EXIF `2026:10:08 14:03:22`.
/// Stored as an ISO-like string `2026-10-08T14:03:22` so it is never shifted by the phone's time zone.
struct LocalDateTime: Codable, Hashable, Comparable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int

    init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        guard isValid else { return nil }
    }

    /// Parses `yyyy-MM-ddTHH:mm:ss` (the storage format).
    init?(iso: String) {
        self.init(string: iso, dateSeparator: "-", dateTimeSeparator: "T")
    }

    /// Parses EXIF `yyyy:MM:dd HH:mm:ss`. Zero or malformed dates return nil.
    init?(exif: String) {
        self.init(string: exif.trimmingCharacters(in: .whitespacesAndNewlines), dateSeparator: ":", dateTimeSeparator: " ")
    }

    /// Wall-clock components of `date` at the given UTC offset.
    init(date: Date, offsetSeconds: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.year = c.year ?? 1970
        self.month = c.month ?? 1
        self.day = c.day ?? 1
        self.hour = c.hour ?? 0
        self.minute = c.minute ?? 0
        self.second = c.second ?? 0
    }

    private init?(string: String, dateSeparator: Character, dateTimeSeparator: Character) {
        let parts = string.split(separator: dateTimeSeparator, maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: dateSeparator)
        // Accept fractional seconds ("14:03:22.123") but ignore the fraction.
        let timeString = parts[1].split(separator: ".").first ?? parts[1]
        let timeParts = timeString.split(separator: ":")
        guard dateParts.count == 3, timeParts.count >= 2,
              let y = Int(dateParts[0]), let mo = Int(dateParts[1]), let d = Int(dateParts[2]),
              let h = Int(timeParts[0]), let mi = Int(timeParts[1]) else { return nil }
        let s = timeParts.count >= 3 ? Int(timeParts[2]) ?? -1 : 0
        self.init(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    var isValid: Bool {
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        return calendar.component(.day, from: date) == day && calendar.component(.month, from: date) == month
    }

    var iso: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, min(second, 59))
    }

    /// The wall clock interpreted as if it were UTC. Only for formatting with a UTC formatter
    /// or for ordering wall-clock values among themselves — not an absolute instant.
    var utcAnchoredDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59))
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Absolute instant for a known UTC offset.
    func instant(offsetSeconds: Int) -> Date {
        utcAnchoredDate.addingTimeInterval(TimeInterval(-offsetSeconds))
    }

    static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        lhs.iso < rhs.iso
    }
}

enum UTCOffset {
    /// Parses EXIF OffsetTime values like `+02:00`, `-05:30`, `+0200`, `Z`.
    static func parse(_ raw: String?) -> Int? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value == "Z" || value == "z" { return 0 }
        guard let signChar = value.first, signChar == "+" || signChar == "-" else { return nil }
        value.removeFirst()
        let digits = value.replacingOccurrences(of: ":", with: "")
        guard digits.count == 4 || digits.count == 2, digits.allSatisfy(\.isNumber),
              let hours = Int(digits.prefix(2)) else { return nil }
        let minutes = digits.count == 4 ? Int(digits.suffix(2)) ?? -1 : 0
        guard (0...14).contains(hours), (0...59).contains(minutes) else { return nil }
        let total = hours * 3600 + minutes * 60
        return signChar == "-" ? -total : total
    }

    /// `UTC+02:00`, `UTC−05:30`, `UTC+00:00`.
    static func display(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let absolute = abs(seconds)
        return String(format: "UTC%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }

    /// Machine form `+02:00` for backups.
    static func machine(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        return String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }
}

/// Where the shown capture time of a photo comes from (TIME-01).
enum DateSourceKind: String, Codable, CaseIterable {
    /// Taken in the app: device clock, with time zone and offset at capture.
    case device
    /// Imported with EXIF date and offset.
    case importedWithOffset
    /// Imported with EXIF date but without offset: wall clock only.
    case importedNoOffset
    /// No capture date is known.
    case unavailable
}

/// The capture time to show for a photo, after applying a manual override if present.
struct PhotoDateInfo: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case device
        case importedWithOffset
        case importedNoOffset
        case manual
        case unavailable
    }

    var kind: Kind
    var local: LocalDateTime?
    var offsetSeconds: Int?

    /// Absolute instant when the offset is known.
    var instant: Date? {
        guard let local, let offsetSeconds else { return nil }
        return local.instant(offsetSeconds: offsetSeconds)
    }

    /// Localization key for the provenance label shown next to the time.
    var provenanceKey: String {
        switch kind {
        case .device: return "provenance.time.device"
        case .importedWithOffset: return "provenance.time.imported"
        case .importedNoOffset: return "provenance.time.importedNoZone"
        case .manual: return "provenance.time.manual"
        case .unavailable: return "provenance.time.unavailable"
        }
    }
}

enum DateStyleOption: String, Codable, CaseIterable, Identifiable {
    /// Localized with month name, e.g. "8 Oct 2026" — never only "03/04".
    case long
    /// ISO preset "2026-10-08".
    case iso

    var id: String { rawValue }
}

enum TimeFormatOption: String, Codable, CaseIterable, Identifiable {
    case system
    case h12
    case h24

    var id: String { rawValue }
}

/// Formats wall-clock values with a formatter fixed to UTC so the phone's current time zone
/// never changes how an already stored capture time is displayed.
struct DateTimeFormatting {
    var locale: Locale
    var dateStyle: DateStyleOption = .long
    var timeFormat: TimeFormatOption = .system
    var includeSeconds = false

    func dateString(_ value: LocalDateTime) -> String {
        switch dateStyle {
        case .iso:
            return String(format: "%04d-%02d-%02d", value.year, value.month, value.day)
        case .long:
            return Self.formatter(template: "yMMMd", locale: locale).string(from: value.utcAnchoredDate)
        }
    }

    func timeString(_ value: LocalDateTime) -> String {
        let template: String
        switch timeFormat {
        case .system: template = includeSeconds ? "jms" : "jm"
        case .h12: template = includeSeconds ? "hmsa" : "hma"
        case .h24: template = includeSeconds ? "Hms" : "Hm"
        }
        return Self.formatter(template: template, locale: locale).string(from: value.utcAnchoredDate)
    }

    func dateTimeString(_ value: LocalDateTime) -> String {
        "\(dateString(value)), \(timeString(value))"
    }

    /// "8 Oct 2026, 14:03 UTC+02:00" or without offset when unknown.
    func dateTimeString(_ value: LocalDateTime, offsetSeconds: Int?) -> String {
        guard let offsetSeconds else { return dateTimeString(value) }
        return "\(dateTimeString(value)) \(UTCOffset.display(offsetSeconds))"
    }

    /// Date of work stored as `yyyy-MM-dd` (no time).
    func workDateString(_ isoDate: String) -> String {
        guard let value = LocalDateTime(iso: isoDate + "T12:00:00") else { return isoDate }
        return dateString(value)
    }

    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    private static func formatter(template: String, locale: Locale) -> DateFormatter {
        let key = "\(locale.identifier)|\(template)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate(template)
        cache[key] = formatter
        return formatter
    }
}

enum WorkDate {
    /// `yyyy-MM-dd` for a calendar day picked in the current time zone.
    static func isoString(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Noon of the stored day in the current calendar (for a DatePicker binding).
    static func date(from iso: String, calendar: Calendar = .current) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
