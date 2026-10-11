import Contacts
import CoreLocation
import Foundation

/// Address for saved coordinates. Only coordinates are sent to the provider (Apple); photos never are.
struct GeocodedAddress: Equatable {
    let text: String
    let resolvedAt: Date
}

/// Provider adapter so the address model does not depend on one (possibly deprecated) API.
/// v1 uses CLGeocoder (system provider, no API key). When the project moves to an SDK where
/// `MKReverseGeocodingRequest` is available, add an adapter here and select it with `#available`.
protocol ReverseGeocodingProvider: Sendable {
    func placemarks(for location: CLLocation, locale: Locale) async throws -> [CLPlacemark]
}

struct CLGeocoderProvider: ReverseGeocodingProvider {
    func placemarks(for location: CLLocation, locale: Locale) async throws -> [CLPlacemark] {
        try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: locale)
    }
}

/// Serial, rate-limited reverse geocoding with a small in-memory cache.
/// A cached address is reused only for coordinates within an explicit radius, never across sites.
actor ReverseGeocodingService {
    enum Precision: Equatable {
        /// Street-level address allowed.
        case precise
        /// Only area/city — never a house number for an approximate position.
        case approximate
    }

    struct CacheEntry {
        let location: CLLocation
        let precision: Precision
        let languageCode: String
        let address: GeocodedAddress
    }

    static let preciseReuseRadius: CLLocationDistance = 25
    static let approximateReuseRadius: CLLocationDistance = 1000
    static let minimumInterval: TimeInterval = 1.2

    private let provider: ReverseGeocodingProvider
    private var cache: [CacheEntry] = []
    private var lastRequestAt: Date?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(provider: ReverseGeocodingProvider = CLGeocoderProvider()) {
        self.provider = provider
    }

    func address(latitude: Double, longitude: Double, precision: Precision, language: AppLanguage) async throws -> GeocodedAddress {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if let cached = cachedAddress(for: location, precision: precision, language: language) { return cached }

        // Serialize requests (one at a time) and keep a minimum interval between them.
        await acquire()
        defer { release() }
        if let cached = cachedAddress(for: location, precision: precision, language: language) { return cached }
        if let last = lastRequestAt {
            let wait = Self.minimumInterval - Date().timeIntervalSince(last)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        try Task.checkCancellation()
        lastRequestAt = Date()

        let placemarks: [CLPlacemark]
        do {
            placemarks = try await provider.placemarks(for: location, locale: language.formattingLocale)
        } catch {
            if (error as? CLError)?.code == .geocodeFoundNoResult { throw AppError(.geocodingNoResult) }
            throw AppError(.geocodingFailed)
        }
        guard let placemark = placemarks.first,
              let text = Self.format(placemark, precision: precision), !text.isEmpty else {
            throw AppError(.geocodingNoResult)
        }
        let address = GeocodedAddress(text: text, resolvedAt: Date())
        cache.append(CacheEntry(location: location, precision: precision, languageCode: language.rawValue, address: address))
        if cache.count > 200 { cache.removeFirst(cache.count - 200) }
        return address
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in waiting.append(continuation) }
        } else {
            busy = true
        }
    }

    /// Hands the slot to the next waiting request (busy stays true) or frees it.
    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func cachedAddress(for location: CLLocation, precision: Precision, language: AppLanguage) -> GeocodedAddress? {
        let radius: CLLocationDistance = precision == .precise ? Self.preciseReuseRadius : Self.approximateReuseRadius
        let code = language.rawValue
        for entry in cache.reversed() where entry.precision == precision && entry.languageCode == code {
            let distance: CLLocationDistance = entry.location.distance(from: location)
            if distance <= radius { return entry.address }
        }
        return nil
    }

    /// The cache holds sensitive data; it is cleared with "Delete all data".
    func clearCache() {
        cache.removeAll()
    }

    /// Formats only what the service returned — no invented apartment or house number.
    static func format(_ placemark: CLPlacemark, precision: Precision) -> String? {
        switch precision {
        case .precise:
            if let postal = placemark.postalAddress {
                let text = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                if !text.isEmpty { return text }
            }
            return areaText(placemark)
        case .approximate:
            return areaText(placemark)
        }
    }

    private static func areaText(_ placemark: CLPlacemark) -> String? {
        var parts: [String] = []
        for value in [placemark.subLocality, placemark.locality, placemark.administrativeArea, placemark.country] {
            if let value, !value.isEmpty, !parts.contains(value) { parts.append(value) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
