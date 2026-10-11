import Foundation

/// Values frozen at the moment of the shutter for one capture ID (CAM-02).
struct CaptureContext {
    let captureID: UUID
    let shutter: Date
    let timeZone: TimeZone
    let projectID: UUID?
    let stamp: StampSettings
    let locationEnabled: Bool
    /// Fresh measurement available at the shutter, if any.
    let immediateFix: LocationFix?
    /// Optional manual location label for this camera session (S05).
    let manualLocationLabel: String?
}

/// Saves captures and imports and keeps their metadata honest:
/// capture → atomic file write → database record → "Saved". Location and address are only ever
/// attached to the capture they were measured for.
@MainActor
final class CaptureCoordinator {
    private let repository: ProjectRepository
    private let files: FileStore
    private let location: LocationService
    private let geocoder: ReverseGeocodingService
    private let analytics: AnalyticsService

    init(repository: ProjectRepository, files: FileStore, location: LocationService,
         geocoder: ReverseGeocodingService, analytics: AnalyticsService) {
        self.repository = repository
        self.files = files
        self.location = location
        self.geocoder = geocoder
        self.analytics = analytics
    }

    /// Writes the original and creates the record. Throws without leaving a "saved" record on failure.
    func saveCapture(_ photo: CapturedPhoto, context: CaptureContext) async throws -> PhotoRecord {
        // Repeated callbacks never create a second record for the same capture.
        if let existing = repository.photo(id: context.captureID) { return existing }

        let relativePath = FileStore.originalRelativePath(photoID: context.captureID, format: photo.format)
        let files = self.files
        let data = photo.data
        let (inspection, hash): (ImageInspection, String) = try await Task.detached(priority: .userInitiated) {
            let inspection = try ImageInspector.inspect(data: data)
            try files.writeAtomically(data, toRelative: relativePath)
            return (inspection, FileStore.sha256(of: data))
        }.value

        let offset = context.timeZone.secondsFromGMT(for: context.shutter)
        let record = PhotoRecord(id: context.captureID, projectID: context.projectID, source: .capture,
                                 originalPath: relativePath, format: photo.format,
                                 pixelWidth: inspection.pixelWidth, pixelHeight: inspection.pixelHeight,
                                 orientation: inspection.orientation, sha256: hash, byteSize: Int64(data.count),
                                 order: repository.nextOrder(projectID: context.projectID), createdAt: context.shutter)
        record.dateSourceRaw = DateSourceKind.device.rawValue
        record.captureInstant = context.shutter
        record.captureLocal = LocalDateTime(date: context.shutter, offsetSeconds: offset).iso
        record.captureOffsetSeconds = offset
        record.captureTimeZoneID = context.timeZone.identifier

        var stamp = StampSnapshot(settings: context.stamp, language: .current)
        stamp.provenanceLabels = []
        record.stamp = stamp

        if context.locationEnabled || context.manualLocationLabel != nil {
            var photoLocation = PhotoLocation(source: .device)
            if context.locationEnabled {
                if let fix = context.immediateFix {
                    fix.applied(to: &photoLocation)
                } else {
                    photoLocation.fixStatus = location.isAuthorized ? .waiting : .unavailable
                }
            }
            if let label = context.manualLocationLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                photoLocation.addressOverride = String(label.prefix(TextLimits.manualAddress))
                photoLocation.addressOverrideKind = .manual
                photoLocation.addressOverrideUpdatedAt = Date()
                if !photoLocation.hasCoordinates { photoLocation.source = .manual }
            }
            record.location = photoLocation
        }
        repository.refreshProvenance(record)

        do {
            try repository.insert(record)
        } catch {
            files.removeItem(relative: relativePath)
            throw error
        }
        repository.usage.recordPhotosAdded()
        analytics.track(.captureSaved)
        Task.detached(priority: .utility) {
            ThumbnailStore.generate(photoID: context.captureID, originalRelativePath: relativePath, files: files)
        }
        followUpLocation(for: record.id, context: context)
        return record
    }

    private func followUpLocation(for photoID: UUID, context: CaptureContext) {
        guard context.locationEnabled else { return }
        if context.immediateFix != nil {
            Task { await lookUpAddress(photoID: photoID) }
            return
        }
        guard location.isAuthorized else { return }
        Task {
            let fix = await location.waitForFix(shutter: context.shutter)
            repository.updateLocation(photoID: photoID) { value in
                if let fix {
                    fix.applied(to: &value)
                } else {
                    value.fixStatus = .unavailable
                }
            }
            if fix != nil { await lookUpAddress(photoID: photoID) }
        }
    }

    /// Reverse geocoding for the coordinates already saved with this photo (also used for retries).
    func lookUpAddress(photoID: UUID) async {
        guard let photo = repository.photo(id: photoID), let saved = photo.location,
              let lat = saved.latitude, let lon = saved.longitude else { return }
        repository.updateLocation(photoID: photoID) { $0.addressStatus = .pending }
        let precision: ReverseGeocodingService.Precision = saved.isApproximate ? .approximate : .precise
        do {
            let address = try await geocoder.address(latitude: lat, longitude: lon, precision: precision, language: .current)
            repository.updateLocation(photoID: photoID) { value in
                // Only apply if the coordinates did not change meanwhile.
                guard value.latitude == lat, value.longitude == lon else { return }
                value.addressOriginal = address.text
                value.addressResolvedAt = address.resolvedAt
                value.addressStatus = .resolved
            }
        } catch {
            let code = (error as? AppError)?.code
            repository.updateLocation(photoID: photoID) { $0.addressStatus = code == .geocodingNoResult ? .noResult : .failed }
        }
    }

    /// Looks up addresses for photos that have coordinates but no address yet (explicit user action).
    func lookUpMissingAddresses(projectID: UUID?) async -> Int {
        let candidates = repository.photos(projectID: projectID).filter {
            guard let location = $0.location else { return false }
            return location.hasCoordinates && location.addressOriginal == nil
        }.map(\.id)
        for id in candidates { await lookUpAddress(photoID: id) }
        return candidates.count
    }
}
