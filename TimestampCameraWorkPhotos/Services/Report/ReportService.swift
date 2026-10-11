import Foundation
import Observation
import UIKit

/// Thread-safe cancellation flag shared with the background renderer.
final class CancellationFlag: @unchecked Sendable {
    enum Reason {
        case user
        /// iOS ended the allowed background time.
        case background
    }

    private let lock = NSLock()
    private var reason: Reason?

    func cancel(_ reason: Reason) {
        lock.lock()
        if self.reason == nil { self.reason = reason }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reason != nil
    }

    var cancelReason: Reason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

enum AppInfo {
    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Stamvio"
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }
}

/// Builds the immutable snapshot and checks limits before anything is rendered (PDF-04).
@MainActor
enum ReportSnapshotFactory {
    static func make(project: Project, settings: ReportSettings, repository: ProjectRepository, isPro: Bool,
                     now: Date = Date(), timeZone: TimeZone = .current) throws -> ReportSnapshot {
        let policy = repository.accessPolicy(isPro: isPro)
        // New reports only for editable projects (Free: the Free project). Saved PDFs stay available.
        switch policy.access(for: project.id) {
        case .editable: break
        case .archived: throw AppError(.projectArchived)
        case .readOnlyNotSelected, .readOnlyTooManyPhotos: throw AppError(.projectReadOnly)
        }
        var photos: [ReportSnapshot.PhotoInfo] = []
        var pairs: [ReportSnapshot.PairInfo] = []

        func info(_ photo: PhotoRecord) -> ReportSnapshot.PhotoInfo {
            let size = ImageGeometry.orientedSize(width: photo.pixelWidth, height: photo.pixelHeight, orientation: photo.orientation)
            return ReportSnapshot.PhotoInfo(id: photo.id, originalPath: photo.originalPath,
                                            orientedWidth: Int(size.width), orientedHeight: Int(size.height),
                                            caption: photo.caption, isImported: photo.isImported,
                                            dateInfo: photo.dateInfo, location: photo.location)
        }

        switch settings.template {
        case .standard:
            let records = repository.photos(ids: settings.selectedPhotoIDs)
                .filter { $0.projectID == project.id && $0.saveState == .saved }
            guard !records.isEmpty else { throw AppError(.reportNothingSelected) }
            // Checked before starting — never silently truncated.
            guard records.count <= policy.reportPhotoLimit else {
                throw AppError(.reportLimitExceeded, arguments: [String(policy.reportPhotoLimit)])
            }
            photos = records.map(info)
        case .beforeAfter:
            for pairID in settings.selectedPairIDs {
                guard let pair = repository.pair(id: pairID), pair.projectID == project.id, pair.isComplete,
                      let before = repository.photo(id: pair.beforePhotoID), before.saveState == .saved,
                      let after = repository.photo(id: pair.afterPhotoID), after.saveState == .saved else { continue }
                pairs.append(ReportSnapshot.PairInfo(id: pair.id, title: pair.title, caption: pair.caption,
                                                     beforeID: before.id, afterID: after.id))
                photos.append(info(before))
                photos.append(info(after))
            }
            guard !pairs.isEmpty else { throw AppError(.reportNothingSelected) }
            let pairLimit = isPro ? AccessPolicy.proReportPairLimit : AccessPolicy.freeReportPhotoLimit / 2
            guard pairs.count <= pairLimit else { throw AppError(.reportLimitExceeded, arguments: [String(pairLimit)]) }
        }

        let prefs = repository.preferences()
        var executorName: String? = prefs.executorName
        var contact: String? = prefs.executorContact
        var logoPath: String? = isPro && settings.includeLogo ? prefs.executorLogoPath : nil
        if isPro, let preset = repository.brandPreset(id: settings.brandPresetID) {
            executorName = preset.executorName
            contact = preset.contactText
            logoPath = settings.includeLogo ? preset.logoPath : nil
        }
        if let path = logoPath, !repository.files.fileExists(relative: path) { logoPath = nil }

        var cleanSettings = settings
        cleanSettings.title = String(settings.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextLimits.reportTitle))
        cleanSettings.summary = String(settings.summary.prefix(TextLimits.reportSummary))
        if !isPro { cleanSettings.brandPresetID = nil }

        return ReportSnapshot(reportID: UUID(), createdAt: now, createdOffsetSeconds: timeZone.secondsFromGMT(for: now),
                              settings: cleanSettings,
                              project: .init(id: project.id, title: project.displayTitle, siteAddress: project.siteAddress,
                                             clientName: project.clientName, workDate: project.workDate),
                              photos: photos, pairs: pairs,
                              branding: .init(executorName: executorName, contactText: contact, logoPath: logoPath,
                                              showCreatedWith: !isPro),
                              isProPreview: settings.template.requiresPro && !isPro,
                              appName: AppInfo.displayName)
    }
}

/// One report generation (S13): progress, cancel, error and retry. Writes a temporary file, checks
/// it, then moves it into Reports and registers it. Only then the report is "ready".
@MainActor
@Observable
final class ReportGenerationJob: Identifiable {
    struct Output: Equatable {
        let url: URL
        let pageCount: Int
        let bytes: Int64
        /// nil for a Pro preview (not saved as a report).
        let reportID: UUID?
        let template: ReportTemplate
        var isPreview: Bool { reportID == nil }
    }

    enum Phase: Equatable {
        case preparing
        case rendering(done: Int, total: Int)
        case verifying
        case ready(Output)
        case failed(AppError)
        case cancelled
    }

    let id = UUID()
    let snapshot: ReportSnapshot
    private(set) var phase: Phase = .preparing
    private let repository: ProjectRepository
    private let files: FileStore
    private let analytics: AnalyticsService
    private var flag = CancellationFlag()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var startedAt = Date()

    init(snapshot: ReportSnapshot, repository: ProjectRepository, analytics: AnalyticsService) {
        self.snapshot = snapshot
        self.repository = repository
        self.files = repository.files
        self.analytics = analytics
    }

    var isRunning: Bool {
        switch phase {
        case .preparing, .rendering, .verifying: return true
        default: return false
        }
    }

    func start() {
        flag = CancellationFlag()
        phase = .preparing
        startedAt = Date()
        let flag = self.flag
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "report") { [weak self] in
            // Not an unlimited background promise: stop safely and offer a retry.
            flag.cancel(.background)
            Task { @MainActor in self?.endBackgroundTask() }
        }
        Task { await run(flag: flag) }
    }

    func cancel() {
        flag.cancel(.user)
    }

    func retry() {
        guard !isRunning else { return }
        start()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func run(flag: CancellationFlag) async {
        defer { endBackgroundTask() }
        let snapshot = self.snapshot
        let files = self.files
        let estimate = Int64(snapshot.photos.count) * snapshot.settings.quality.estimatedBytesPerPhoto * 2 + 10_000_000
        do {
            try files.ensureSpace(for: estimate)
        } catch {
            phase = .failed(AppError(.insufficientStorage))
            return
        }

        var leased = snapshot.photos.map(\.originalPath)
        if let logo = snapshot.branding.logoPath { leased.append(logo) }
        let lease = files.lease(leased)
        defer { files.endLease(lease) }

        let tempURL = files.tempRoot.appendingPathComponent("report-\(snapshot.reportID.uuidString).pdf")
        try? FileManager.default.createDirectory(at: files.tempRoot, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: tempURL)

        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> ReportBuilder.Result in
                try ReportBuilder(snapshot: snapshot, files: files).build(to: tempURL, progress: { done, total in
                    Task { @MainActor [weak self] in
                        if self?.isRunning == true { self?.phase = .rendering(done: done, total: total) }
                    }
                }, isCancelled: { flag.isCancelled })
            }.value
            if flag.isCancelled { throw AppError(.reportCancelled) }
            phase = .verifying
            let verified = await Task.detached { ReportBuilder.verify(url: tempURL, expectedPages: result.pageCount) }.value
            guard verified else { throw AppError(.reportVerificationFailed) }
            if flag.isCancelled { throw AppError(.reportCancelled) }

            let bytes = Int64((try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if snapshot.isProPreview {
                phase = .ready(Output(url: tempURL, pageCount: result.pageCount, bytes: bytes, reportID: nil,
                                      template: snapshot.settings.template))
                return
            }
            let output = try register(tempURL: tempURL, pageCount: result.pageCount, bytes: bytes)
            phase = .ready(output)
            analytics.track(.reportGenerated(template: snapshot.settings.template, photoCount: snapshot.photos.count,
                                             duration: Date().timeIntervalSince(startedAt)))
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            let appError = AppError.wrap(error, default: .reportGenerationFailed)
            if appError.code == .reportCancelled {
                phase = flag.cancelReason == .background ? .failed(AppError(.reportInterrupted)) : .cancelled
            } else {
                ErrorLog.shared.record(appError.code)
                analytics.track(.error(code: appError.code, source: .report))
                phase = .failed(appError)
            }
        }
    }

    /// Moves the verified file into Reports/<id>/ with its snapshot and creates the ReportVersion.
    private func register(tempURL: URL, pageCount: Int, bytes: Int64) throws -> Output {
        let reportID = snapshot.reportID
        let directory = FileStore.reportDirectoryRelativePath(reportID: reportID)
        let fileName = ReportNaming.fileName(projectTitle: snapshot.project.title, date: snapshot.createdAt, reportID: reportID)
        let pdfPath = "\(directory)/\(fileName)"
        let snapshotPath = "\(directory)/snapshot.json"
        do {
            let json = try JSONBlob.encoder.encode(snapshot)
            try files.writeAtomically(json, toRelative: snapshotPath)
            try files.moveIntoStore(from: tempURL, toRelative: pdfPath)
            let version = ReportVersion(id: reportID, projectID: snapshot.project.id, createdAt: snapshot.createdAt,
                                        language: snapshot.settings.language, pageSize: snapshot.settings.pageSize,
                                        template: snapshot.settings.template, templateVersion: ReportSnapshot.templateVersion,
                                        title: snapshot.settings.title.isEmpty ? snapshot.project.title : snapshot.settings.title,
                                        snapshotPath: snapshotPath, pdfPath: pdfPath, fileName: fileName,
                                        pageCount: pageCount, bytes: bytes, photoCount: snapshot.photos.count,
                                        pairCount: snapshot.pairs.count, includedPhotoIDs: snapshot.includedPhotoIDs)
            try repository.register(version)
            return Output(url: try files.url(forRelative: pdfPath), pageCount: pageCount, bytes: bytes, reportID: reportID,
                          template: snapshot.settings.template)
        } catch {
            files.removeItem(relative: directory)
            throw AppError.wrap(error, default: .reportGenerationFailed)
        }
    }
}
