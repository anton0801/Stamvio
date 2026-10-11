import Foundation
import Observation
import SwiftData

/// Editable fields of a project (S07). Only the title is required.
struct ProjectDraft: Equatable {
    var title = ""
    var siteAddress = ""
    var clientName = ""
    var notes = ""
    var workDate: Date?

    init() {}

    init(project: Project) {
        title = project.title
        siteAddress = project.siteAddress
        clientName = project.clientName
        notes = project.notes
        workDate = project.workDate.flatMap { WorkDate.date(from: $0) }
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedTitle.isEmpty && trimmedTitle.count <= TextLimits.projectTitle }

    func normalized() -> ProjectDraft {
        var copy = self
        copy.title = String(trimmedTitle.prefix(TextLimits.projectTitle))
        copy.siteAddress = String(siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.siteAddress))
        copy.clientName = String(clientName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.clientName))
        copy.notes = String(notes.prefix(TextLimits.projectNotes))
        return copy
    }
}

enum PhotoSortMode {
    /// Order in which photos were added.
    case added
    /// Known capture date first (full timestamp, then wall clock without zone), photos without date last.
    case captureDate
}

/// All database reads and writes go through here (on the main actor). File operations are
/// delegated to `FileStore`. Every successful save bumps `revision` so views can refresh counts.
@MainActor
@Observable
final class ProjectRepository {
    let container: ModelContainer
    let files: FileStore
    /// Lifetime Free quota (photos added, projects created).
    let usage: UsageLedger
    private(set) var revision = 0

    var context: ModelContext { container.mainContext }

    init(container: ModelContainer, files: FileStore, usage: UsageLedger) {
        self.container = container
        self.files = files
        self.usage = usage
    }

    /// The quota never drops below what exists on the device (older data, backups, recovered files).
    func reconcileUsage() {
        usage.reconcile(existingPhotos: allPhotosEverywhere().count, existingProjects: allProjects().count)
    }

    func save() throws {
        do {
            if context.hasChanges { try context.save() }
            revision += 1
        } catch {
            context.rollback()
            throw AppError(.databaseSaveFailed)
        }
    }

    // MARK: Preferences

    func preferences() -> AppPreferences {
        let key = AppPreferences.singletonKey
        var descriptor = FetchDescriptor<AppPreferences>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = AppPreferences()
        context.insert(created)
        try? save()
        return created
    }

    // MARK: Projects

    func allProjects() -> [Project] {
        (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func activeProjects() -> [Project] {
        allProjects().filter { !$0.isArchived }
    }

    /// Visible photos: saved ones and ones whose file is missing (shown with a warning, never hidden).
    func photoCount(projectID: UUID?) -> Int {
        let pid = projectID
        let saved = SaveState.saved.rawValue
        let missing = SaveState.missingFile.rawValue
        let descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate {
            $0.projectID == pid && ($0.saveStateRaw == saved || $0.saveStateRaw == missing)
        })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func projectUsage() -> [AccessPolicy.ProjectUsage] {
        allProjects().map { AccessPolicy.ProjectUsage(id: $0.id, photoCount: photoCount(projectID: $0.id), isArchived: $0.isArchived) }
    }

    func accessPolicy(isPro: Bool) -> AccessPolicy {
        AccessPolicy(isPro: isPro, projects: projectUsage(), selectedFreeProjectID: preferences().selectedFreeProjectID,
                     usage: usage.usage, photoQuota: usage.photoQuota)
    }

    /// Persists the automatic Free selection so it does not jump between projects later.
    func persistFreeSelectionIfNeeded(isPro: Bool) {
        guard !isPro else { return }
        let policy = accessPolicy(isPro: false)
        let prefs = preferences()
        if let resolved = policy.freeEditableProjectID, prefs.selectedFreeProjectID != resolved {
            prefs.selectedFreeProjectID = resolved
            try? save()
        }
    }

    func selectFreeProject(_ projectID: UUID) throws {
        preferences().selectedFreeProjectID = projectID
        try save()
    }

    @discardableResult
    func createProject(_ draft: ProjectDraft, makeFreeProject: Bool) throws -> Project {
        let clean = draft.normalized()
        guard clean.isValid else { throw AppError(.validationFailed) }
        let project = Project(title: clean.title, siteAddress: clean.siteAddress, clientName: clean.clientName,
                              notes: clean.notes, workDate: clean.workDate.map { WorkDate.isoString(from: $0) })
        var defaults = ReportDefaults()
        defaults.language = preferences().reportLanguage
        defaults.pageSize = preferences().defaultPageSize
        project.reportDefaults = defaults
        context.insert(project)
        if makeFreeProject { preferences().selectedFreeProjectID = project.id }
        try save()
        usage.recordProjectCreated()
        return project
    }

    func update(_ project: Project, with draft: ProjectDraft) throws {
        let clean = draft.normalized()
        guard clean.isValid else { throw AppError(.validationFailed) }
        project.title = clean.title
        project.siteAddress = clean.siteAddress
        project.clientName = clean.clientName
        project.notes = clean.notes
        project.workDate = clean.workDate.map { WorkDate.isoString(from: $0) }
        project.updatedAt = Date()
        try save()
    }

    func setArchived(_ project: Project, archived: Bool) throws {
        project.archivedAt = archived ? Date() : nil
        project.updatedAt = Date()
        try save()
    }

    func saveReportDefaults(_ defaults: ReportDefaults, for project: Project) {
        project.reportDefaults = defaults
        try? save()
    }

    /// Deletes the project, its photos, pairs and its saved reports. Files exported elsewhere are not affected.
    func deleteProject(_ project: Project) throws {
        let projectID = project.id
        let photos = allPhotos(projectID: projectID)
        for photo in photos { photo.saveStateRaw = SaveState.deleting.rawValue }
        try save()

        for pair in pairs(projectID: projectID) { context.delete(pair) }
        for report in reports(projectID: projectID) { deleteReportFiles(report); context.delete(report) }
        for photo in photos { deletePhotoFiles(photo); context.delete(photo) }
        let prefs = preferences()
        if prefs.selectedFreeProjectID == projectID { prefs.selectedFreeProjectID = nil }
        if prefs.cameraProjectID == projectID { prefs.cameraProjectID = nil }
        context.delete(project)
        try save()
    }

    // MARK: Photos

    /// Visible photos of a project (or Unsorted) in their explicit order.
    func photos(projectID: UUID?) -> [PhotoRecord] {
        let pid = projectID
        let saved = SaveState.saved.rawValue
        let missing = SaveState.missingFile.rawValue
        let descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate {
            $0.projectID == pid && ($0.saveStateRaw == saved || $0.saveStateRaw == missing)
        }, sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Includes photos in any save state.
    func allPhotos(projectID: UUID?) -> [PhotoRecord] {
        let pid = projectID
        let descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.projectID == pid })
        return (try? context.fetch(descriptor)) ?? []
    }

    func allPhotosEverywhere() -> [PhotoRecord] {
        (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
    }

    func photo(id: UUID?) -> PhotoRecord? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func photos(ids: [UUID]) -> [PhotoRecord] {
        ids.compactMap { photo(id: $0) }
    }

    func nextOrder(projectID: UUID?) -> Int {
        let pid = projectID
        var descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.projectID == pid },
                                                      sortBy: [SortDescriptor(\.order, order: .reverse)])
        descriptor.fetchLimit = 1
        let last = (try? context.fetch(descriptor).first?.order) ?? -1
        return last + 1
    }

    /// Duplicate hint by SHA-256 within the same project (never deletes anything).
    func existingPhoto(sha256: String, projectID: UUID?) -> PhotoRecord? {
        let pid = projectID
        let hash = sha256
        let saved = SaveState.saved.rawValue
        var descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate {
            $0.projectID == pid && $0.sha256 == hash && $0.saveStateRaw == saved
        })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func insert(_ photo: PhotoRecord) throws {
        context.insert(photo)
        touchProject(photo.projectID)
        do {
            try save()
        } catch {
            context.delete(photo)
            throw error
        }
    }

    private func touchProject(_ projectID: UUID?) {
        project(id: projectID)?.updatedAt = Date()
    }

    func updateCaption(_ photo: PhotoRecord, caption: String, shortCaption: String?) throws {
        photo.caption = String(caption.prefix(TextLimits.caption))
        var stamp = photo.stamp ?? StampSnapshot(settings: preferences().defaultStamp, language: .current)
        let short = shortCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        stamp.customShortCaption = (short?.isEmpty ?? true) ? nil : String(short!.prefix(TextLimits.stampCaption))
        photo.stamp = stamp
        photo.updatedAt = Date()
        touchProject(photo.projectID)
        try save()
    }

    /// Manual date stored separately; the original capture values stay unchanged.
    func setManualDate(_ photo: PhotoRecord, date: Date, timeZone: TimeZone = .current) throws {
        let offset = timeZone.secondsFromGMT(for: date)
        photo.manualDateLocal = LocalDateTime(date: date, offsetSeconds: offset).iso
        photo.manualDateOffsetSeconds = offset
        photo.manualDateTimeZoneID = timeZone.identifier
        photo.manualDateUpdatedAt = Date()
        photo.updatedAt = Date()
        refreshProvenance(photo)
        try save()
    }

    func clearManualDate(_ photo: PhotoRecord) throws {
        photo.manualDateLocal = nil
        photo.manualDateOffsetSeconds = nil
        photo.manualDateTimeZoneID = nil
        photo.manualDateUpdatedAt = Date()
        photo.updatedAt = Date()
        refreshProvenance(photo)
        try save()
    }

    /// Manual location label: keeps any automatic address and coordinates; creates no coordinates.
    func setAddressOverride(_ photo: PhotoRecord, text: String, kind: AddressOverrideKind) throws {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.manualAddress))
        var location = photo.location ?? PhotoLocation(source: kind == .project ? .project : .manual)
        if trimmed.isEmpty {
            location.addressOverride = nil
            location.addressOverrideKind = nil
        } else {
            location.addressOverride = trimmed
            location.addressOverrideKind = kind
        }
        location.addressOverrideUpdatedAt = Date()
        photo.location = location.isEmpty && location.addressOriginal == nil ? nil : location
        photo.updatedAt = Date()
        refreshProvenance(photo)
        try save()
    }

    func clearAddressOverride(_ photo: PhotoRecord) throws {
        guard var location = photo.location else { return }
        location.addressOverride = nil
        location.addressOverrideKind = nil
        location.addressOverrideUpdatedAt = Date()
        photo.location = (location.hasCoordinates || location.addressOriginal != nil) ? location : nil
        photo.updatedAt = Date()
        refreshProvenance(photo)
        try save()
    }

    /// Updates a photo's measured location. Only used for the capture it was measured for.
    func updateLocation(photoID: UUID, _ transform: (inout PhotoLocation) -> Void) {
        guard let photo = photo(id: photoID) else { return }
        var location = photo.location ?? PhotoLocation(source: .device)
        transform(&location)
        photo.location = location
        photo.updatedAt = Date()
        refreshProvenance(photo)
        try? save()
    }

    func refreshProvenance(_ photo: PhotoRecord) {
        guard var stamp = photo.stamp else { return }
        stamp.provenanceLabels = ProvenanceLabels.labels(for: photo)
        photo.stamp = stamp
    }

    func applyStamp(_ settings: StampSettings, to photos: [PhotoRecord]) throws {
        for photo in photos {
            var stamp = photo.stamp ?? StampSnapshot(settings: settings, language: .current)
            stamp.settings = settings
            stamp.templateVersion = StampSnapshot.currentTemplateVersion
            stamp.formattingLanguage = .current
            stamp.provenanceLabels = ProvenanceLabels.labels(for: photo)
            photo.stamp = stamp
            photo.updatedAt = Date()
        }
        try save()
    }

    func updateStamp(_ photo: PhotoRecord, settings: StampSettings) throws {
        try applyStamp(settings, to: [photo])
    }

    /// Moves photos to another project or to Unsorted (nil). Files are not touched.
    /// Pairs in the old project lose the moved photos (they become drafts).
    func move(_ photos: [PhotoRecord], to projectID: UUID?) throws {
        var order = nextOrder(projectID: projectID)
        for photo in photos where photo.projectID != projectID {
            removeFromPairs(photoID: photo.id)
            touchProject(photo.projectID)
            photo.projectID = projectID
            photo.order = order
            photo.updatedAt = Date()
            order += 1
        }
        touchProject(projectID)
        try save()
    }

    /// Saves an explicit order (drag & drop or a sort command).
    func setOrder(_ orderedIDs: [UUID], projectID: UUID?) throws {
        let byID = Dictionary(uniqueKeysWithValues: photos(projectID: projectID).map { ($0.id, $0) })
        var index = 0
        for id in orderedIDs {
            guard let photo = byID[id] else { continue }
            photo.order = index
            index += 1
        }
        // Photos not in the list (should not happen) go to the end in their old order.
        for photo in byID.values.sorted(by: { $0.order < $1.order }) where !orderedIDs.contains(photo.id) {
            photo.order = index
            index += 1
        }
        touchProject(projectID)
        try save()
    }

    func sort(projectID: UUID?, mode: PhotoSortMode) throws {
        let sorted = PhotoOrdering.sorted(photos(projectID: projectID), mode: mode)
        try setOrder(sorted.map(\.id), projectID: projectID)
    }

    /// Reports that contain any of the photos.
    func reportsIncluding(photoIDs: [UUID]) -> [ReportVersion] {
        let all = (try? context.fetch(FetchDescriptor<ReportVersion>())) ?? []
        return all.filter { report in photoIDs.contains(where: { report.includes(photoID: $0) }) }
    }

    /// Deletes photos (and optionally the given local reports that contain them).
    /// Order: mark "deleting" → remove from pairs → delete files → delete records. Reconciliation
    /// finishes the job if the app is closed in the middle.
    func deletePhotos(_ photos: [PhotoRecord], alsoDeleteReports reportsToDelete: [ReportVersion] = []) throws {
        guard !photos.isEmpty else { return }
        for photo in photos { photo.saveStateRaw = SaveState.deleting.rawValue }
        try save()
        for photo in photos {
            removeFromPairs(photoID: photo.id)
            touchProject(photo.projectID)
            deletePhotoFiles(photo)
            context.delete(photo)
        }
        for report in reportsToDelete {
            deleteReportFiles(report)
            context.delete(report)
        }
        try save()
    }

    private func deletePhotoFiles(_ photo: PhotoRecord) {
        files.removeItem(relative: photo.originalPath)
        files.removeThumbnail(for: photo.id)
    }

    // MARK: Pairs (PAIR-01)

    func pairs(projectID: UUID) -> [PhotoPair] {
        let pid = projectID
        let descriptor = FetchDescriptor<PhotoPair>(predicate: #Predicate { $0.projectID == pid },
                                                    sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func pair(id: UUID?) -> PhotoPair? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<PhotoPair>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func pair(containing photoID: UUID) -> PhotoPair? {
        let all = (try? context.fetch(FetchDescriptor<PhotoPair>())) ?? []
        return all.first { $0.contains(photoID) }
    }

    /// Validates that a pair is allowed: different photos, same project, each photo in at most one pair.
    func validatePair(projectID: UUID, before: UUID?, after: UUID?, excludingPairID: UUID?) -> Bool {
        if let before, let after, before == after { return false }
        for photoID in [before, after].compactMap({ $0 }) {
            guard let photo = photo(id: photoID), photo.projectID == projectID, photo.saveState == .saved else { return false }
            if let other = pair(containing: photoID), other.id != excludingPairID { return false }
        }
        return true
    }

    @discardableResult
    func createPair(projectID: UUID, before: UUID?, after: UUID?, title: String, caption: String) throws -> PhotoPair {
        guard validatePair(projectID: projectID, before: before, after: after, excludingPairID: nil) else {
            throw AppError(.pairInvalid)
        }
        let order = (pairs(projectID: projectID).map(\.order).max() ?? -1) + 1
        let pair = PhotoPair(projectID: projectID, beforePhotoID: before, afterPhotoID: after,
                             title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.pairTitle)),
                             caption: String(caption.prefix(TextLimits.pairCaption)), order: order)
        context.insert(pair)
        touchProject(projectID)
        try save()
        return pair
    }

    func updatePair(_ pair: PhotoPair, before: UUID?, after: UUID?, title: String, caption: String) throws {
        guard validatePair(projectID: pair.projectID, before: before, after: after, excludingPairID: pair.id) else {
            throw AppError(.pairInvalid)
        }
        pair.beforePhotoID = before
        pair.afterPhotoID = after
        pair.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.pairTitle))
        pair.caption = String(caption.prefix(TextLimits.pairCaption))
        pair.refreshState()
        pair.updatedAt = Date()
        touchProject(pair.projectID)
        try save()
    }

    func deletePair(_ pair: PhotoPair) throws {
        touchProject(pair.projectID)
        context.delete(pair)
        try save()
    }

    func setPairOrder(_ orderedIDs: [UUID], projectID: UUID) throws {
        let byID = Dictionary(uniqueKeysWithValues: pairs(projectID: projectID).map { ($0.id, $0) })
        for (index, id) in orderedIDs.enumerated() { byID[id]?.order = index }
        try save()
    }

    /// Removing a photo from a pair turns the pair into a draft (never a "complete" pair with a hole).
    private func removeFromPairs(photoID: UUID) {
        let all = (try? context.fetch(FetchDescriptor<PhotoPair>())) ?? []
        for pair in all where pair.contains(photoID) {
            if pair.beforePhotoID == photoID { pair.beforePhotoID = nil }
            if pair.afterPhotoID == photoID { pair.afterPhotoID = nil }
            pair.refreshState()
            pair.updatedAt = Date()
        }
    }

    // MARK: Reports (PDF-05)

    func reports(projectID: UUID) -> [ReportVersion] {
        let pid = projectID
        let descriptor = FetchDescriptor<ReportVersion>(predicate: #Predicate { $0.projectID == pid },
                                                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func allReports() -> [ReportVersion] {
        (try? context.fetch(FetchDescriptor<ReportVersion>())) ?? []
    }

    func report(id: UUID?) -> ReportVersion? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<ReportVersion>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func register(_ report: ReportVersion) throws {
        context.insert(report)
        touchProject(report.projectID)
        do {
            try save()
        } catch {
            context.delete(report)
            throw error
        }
    }

    func deleteReport(_ report: ReportVersion) throws {
        deleteReportFiles(report)
        context.delete(report)
        try save()
    }

    private func deleteReportFiles(_ report: ReportVersion) {
        files.removeItem(relative: FileStore.reportDirectoryRelativePath(reportID: report.id))
    }

    // MARK: Brand presets (Pro)

    func brandPresets() -> [BrandPreset] {
        (try? context.fetch(FetchDescriptor<BrandPreset>(sortBy: [SortDescriptor(\.createdAt)])) ) ?? []
    }

    func brandPreset(id: UUID?) -> BrandPreset? {
        guard let id else { return nil }
        return brandPresets().first { $0.id == id }
    }

    @discardableResult
    func createBrandPreset(title: String, executorName: String, contactText: String, logoPath: String?) throws -> BrandPreset {
        guard brandPresets().count < AccessPolicy.brandPresetLimit else { throw AppError(.validationFailed) }
        let preset = BrandPreset(title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.presetTitle)),
                                 executorName: String(executorName.prefix(TextLimits.executorName)),
                                 contactText: String(contactText.prefix(TextLimits.contactText)), logoPath: logoPath)
        context.insert(preset)
        try save()
        return preset
    }

    func updateBrandPreset(_ preset: BrandPreset, title: String, executorName: String, contactText: String, logoPath: String?) throws {
        if let old = preset.logoPath, old != logoPath { files.removeItem(relative: old) }
        preset.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.presetTitle))
        preset.executorName = String(executorName.prefix(TextLimits.executorName))
        preset.contactText = String(contactText.prefix(TextLimits.contactText))
        preset.logoPath = logoPath
        preset.updatedAt = Date()
        try save()
    }

    func deleteBrandPreset(_ preset: BrandPreset) throws {
        if let logo = preset.logoPath { files.removeItem(relative: logo) }
        context.delete(preset)
        try save()
    }

    // MARK: Delete all

    /// Removes every record. Files are removed by the caller through `FileStore.deleteAllUserFiles()`.
    func deleteAllRecords() throws {
        try context.delete(model: PhotoPair.self)
        try context.delete(model: ReportVersion.self)
        try context.delete(model: PhotoRecord.self)
        try context.delete(model: Project.self)
        try context.delete(model: BrandPreset.self)
        try context.delete(model: AppPreferences.self)
        try save()
    }
}

/// Sorting rules (PROJ-02).
enum PhotoOrdering {
    static func sorted(_ photos: [PhotoRecord], mode: PhotoSortMode) -> [PhotoRecord] {
        switch mode {
        case .added:
            return photos.sorted { lhs, rhs in
                let l = lhs.importedAt ?? lhs.createdAt
                let r = rhs.importedAt ?? rhs.createdAt
                return l == r ? lhs.order < rhs.order : l < r
            }
        case .captureDate:
            let keyed = photos.map { (photo: $0, key: sortKey(for: $0.dateInfo)) }
            return keyed.sorted { lhs, rhs in
                if lhs.key.group != rhs.key.group { return lhs.key.group < rhs.key.group }
                if lhs.key.value != rhs.key.value { return lhs.key.value < rhs.key.value }
                return lhs.photo.order < rhs.photo.order
            }.map(\.photo)
        }
    }

    /// Group 0: absolute instants. Group 1: wall clock without time zone (ordered only among
    /// themselves — no invented absolute order). Group 2: no capture time.
    static func sortKey(for info: PhotoDateInfo) -> (group: Int, value: Double) {
        if let instant = info.instant { return (0, instant.timeIntervalSince1970) }
        if let local = info.local { return (1, local.utcAnchoredDate.timeIntervalSince1970) }
        return (2, 0)
    }
}

/// Provenance labels for stamps, details and reports.
enum ProvenanceLabels {
    static func labels(for photo: PhotoRecord) -> [String] {
        var labels: [String] = []
        if photo.isImported { labels.append("imported") }
        switch photo.dateInfo.kind {
        case .manual: labels.append("manualDate")
        case .importedNoOffset: labels.append("timeZoneUnknown")
        case .unavailable: labels.append("captureTimeUnavailable")
        default: break
        }
        if let location = photo.location {
            if location.isApproximate { labels.append("approximateLocation") }
            switch location.displayAddressKind {
            case .manual: labels.append("manualLocation")
            case .project: labels.append("projectAddress")
            default: break
            }
        }
        return labels
    }
}
