import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// File received from PhotosPicker, copied into Staging. The original in Photos is never changed.
struct PickedImageFile: Transferable {
    /// Staged copy, or nil when the file was rejected before copying.
    let url: URL?
    /// Size of a file rejected for exceeding the per-file limit (checked before any copy).
    let rejectedSize: Int64?
    /// Not enough free space to stage the file (checked before the copy).
    var rejectedForSpace = false

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let size = (try? received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if size > ImportLimits.maxFileBytes {
                return PickedImageFile(url: nil, rejectedSize: size)
            }
            let store = FileStore.live()
            // Staging and the later copy into Originals both need room (checked separately from the size limit).
            if let available = store.availableCapacity(), available < size * 2 + FileStore.safetyMargin {
                return PickedImageFile(url: nil, rejectedSize: nil, rejectedForSpace: true)
            }
            let ext = received.file.pathExtension.isEmpty ? "img" : received.file.pathExtension
            let destination = store.newStagingURL(fileExtension: ext)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedImageFile(url: destination, rejectedSize: nil)
        }
    }
}

/// One import batch with a status per item (IMP-01). Partial failures keep everything already
/// saved; only failed items can be retried.
@MainActor
@Observable
final class ImportSession: Identifiable {
    enum Status: Equatable {
        case waiting
        case loading
        case saved
        case failed(AppError)
        case cancelled
        /// Same SHA-256 already in this project: skipped unless the user imports it anyway.
        case duplicate
    }

    struct Item: Identifiable {
        let id = UUID()
        let pickerItem: PhotosPickerItem
        var status: Status = .waiting
        var photoID: UUID?
        var forceDuplicate = false
    }

    let id = UUID()
    let projectID: UUID?
    private(set) var items: [Item]
    private(set) var isRunning = false
    private var currentProgress: Progress?
    private var cancelRequested = false
    private let repository: ProjectRepository
    private let files: FileStore
    private let analytics: AnalyticsService
    /// Returns how many more photos the target may receive right now.
    private let remainingSlots: () -> Int

    init(projectID: UUID?, pickerItems: [PhotosPickerItem], repository: ProjectRepository, files: FileStore,
         analytics: AnalyticsService, remainingSlots: @escaping () -> Int) {
        self.projectID = projectID
        self.items = pickerItems.map { Item(pickerItem: $0) }
        self.repository = repository
        self.files = files
        self.analytics = analytics
        self.remainingSlots = remainingSlots
    }

    var savedCount: Int { items.filter { $0.status == .saved }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true } else { return false } }.count }
    var duplicateCount: Int { items.filter { $0.status == .duplicate }.count }
    var isFinished: Bool { !isRunning && !items.contains { $0.status == .waiting || $0.status == .loading } }

    func start() {
        guard !isRunning else { return }
        cancelRequested = false
        isRunning = true
        Task { await run() }
    }

    func cancel() {
        cancelRequested = true
        currentProgress?.cancel()
        for index in items.indices where items[index].status == .waiting {
            items[index].status = .cancelled
        }
    }

    func retryFailed() {
        for index in items.indices {
            switch items[index].status {
            case .failed, .cancelled: items[index].status = .waiting
            default: break
            }
        }
        start()
    }

    func importDuplicateAnyway(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].status == .duplicate else { return }
        items[index].forceDuplicate = true
        items[index].status = .waiting
        start()
    }

    private func run() async {
        defer {
            isRunning = false
            currentProgress = nil
        }
        while let index = items.firstIndex(where: { $0.status == .waiting }) {
            if cancelRequested { break }
            if remainingSlots() <= 0 {
                items[index].status = .failed(AppError(.importLimitReached))
                continue
            }
            items[index].status = .loading
            do {
                let photoID = try await importItem(items[index])
                items[index].photoID = photoID
                items[index].status = .saved
            } catch is ImportDuplicate {
                items[index].status = .duplicate
            } catch {
                if cancelRequested {
                    items[index].status = .cancelled
                } else {
                    let appError = AppError.wrap(error, default: .importLoadFailed)
                    ErrorLog.shared.record(appError.code)
                    items[index].status = .failed(appError)
                }
            }
        }
        analytics.track(.importCompleted(photoCount: savedCount, failedCount: failedCount))
    }

    private struct ImportDuplicate: Error {}

    private func load(_ pickerItem: PhotosPickerItem) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let progress = pickerItem.loadTransferable(type: PickedImageFile.self) { result in
                switch result {
                case .success(let file?):
                    if let url = file.url {
                        continuation.resume(returning: url)
                    } else if file.rejectedForSpace {
                        continuation.resume(throwing: AppError(.insufficientStorage))
                    } else {
                        continuation.resume(throwing: AppError(.importFileTooLarge, arguments: [ByteFormatting.string(ImportLimits.maxFileBytes)]))
                    }
                case .success(nil): continuation.resume(throwing: AppError(.importLoadFailed))
                case .failure(let error):
                    if let appError = error as? AppError { continuation.resume(throwing: appError) }
                    else { continuation.resume(throwing: AppError(.importLoadFailed)) }
                }
            }
            Task { @MainActor in self.currentProgress = progress }
        }
    }

    private func importItem(_ item: Item) async throws -> UUID {
        let stagedURL = try await load(item.pickerItem)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        if cancelRequested { throw AppError(.importLoadFailed) }

        let files = self.files
        let projectID = self.projectID
        // Validate type, size and pixel count before decoding; hash for the duplicate hint.
        let (inspection, hash, size): (ImageInspection, String, Int64) = try await Task.detached(priority: .userInitiated) {
            let size = Int64((try? stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > ImportLimits.maxFileBytes {
                throw AppError(.importFileTooLarge, arguments: [ByteFormatting.string(ImportLimits.maxFileBytes)])
            }
            let inspection = try ImageInspector.inspect(url: stagedURL)
            try ImportLimits.validate(fileSize: size, inspection: inspection)
            // A tiny decode proves the file is readable before it is accepted.
            guard ImageLoader.orientedImage(url: stagedURL, maxPixel: 64) != nil else { throw AppError(.importCorrupted) }
            return (inspection, try FileStore.sha256(of: stagedURL), size)
        }.value

        if !item.forceDuplicate, repository.existingPhoto(sha256: hash, projectID: projectID) != nil {
            throw ImportDuplicate()
        }

        let photoID = UUID()
        let relativePath = FileStore.originalRelativePath(photoID: photoID, format: inspection.format)
        try files.ensureSpace(for: size)
        try await Task.detached(priority: .userInitiated) {
            // Staging and Originals are on the same volume: a copy then an atomic rename.
            try files.copyIntoStore(from: stagedURL, toRelative: relativePath)
        }.value

        let now = Date()
        let record = PhotoRecord(id: photoID, projectID: projectID, source: .import, originalPath: relativePath,
                                 format: inspection.format, pixelWidth: inspection.pixelWidth,
                                 pixelHeight: inspection.pixelHeight, orientation: inspection.orientation,
                                 sha256: hash, byteSize: size, order: repository.nextOrder(projectID: projectID),
                                 createdAt: now)
        record.importedAt = now
        Self.applyMetadata(inspection, to: record)
        record.stamp = StampSnapshot(settings: repository.preferences().defaultStamp, language: .current)
        repository.refreshProvenance(record)

        do {
            try repository.insert(record)
        } catch {
            files.removeItem(relative: relativePath)
            throw error
        }
        repository.usage.recordPhotosAdded()
        Task.detached(priority: .utility) {
            ThumbnailStore.generate(photoID: photoID, originalRelativePath: relativePath, files: files)
        }
        return photoID
    }

    /// TIME-01: EXIF with offset → absolute instant; without offset → wall clock only; no date →
    /// unavailable. The import time is never used as capture time. The phone's current location is
    /// never used as the place of an imported photo.
    static func applyMetadata(_ inspection: ImageInspection, to record: PhotoRecord) {
        if let exif = inspection.exifDate {
            record.captureLocal = exif.local.iso
            record.captureRaw = [exif.raw, exif.rawOffset].compactMap { $0 }.joined(separator: " ")
            if let offset = exif.offsetSeconds {
                record.dateSourceRaw = DateSourceKind.importedWithOffset.rawValue
                record.captureOffsetSeconds = offset
                record.captureInstant = exif.local.instant(offsetSeconds: offset)
            } else {
                record.dateSourceRaw = DateSourceKind.importedNoOffset.rawValue
                record.captureOffsetSeconds = nil
                record.captureInstant = nil
            }
        } else {
            record.dateSourceRaw = DateSourceKind.unavailable.rawValue
            record.captureLocal = nil
            record.captureInstant = nil
        }
        if let gps = inspection.gps {
            var location = PhotoLocation(source: .exif)
            location.latitude = gps.latitude
            location.longitude = gps.longitude
            location.horizontalAccuracy = gps.horizontalAccuracy
            location.measuredAt = gps.timestamp
            location.fixStatus = .notRequested
            record.location = location
        }
    }
}
