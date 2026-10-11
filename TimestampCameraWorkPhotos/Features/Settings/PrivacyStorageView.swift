import SwiftUI
import UniformTypeIdentifiers

/// S18 privacy and storage.
struct PrivacyStorageView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sizes = StorageSizes()
    @State private var confirmClearCache = false
    @State private var confirmDeleteStep1 = false
    @State private var confirmDeleteStep2 = false
    @State private var backupScope: IdentifiedScope?
    @State private var toast: ToastMessage?
    @State private var error: AppError?

    struct StorageSizes {
        var originals: Int64 = 0
        var reports: Int64 = 0
        var logos: Int64 = 0
        var cache: Int64 = 0
        var free: Int64?
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("location.toggle"), isOn: Binding(get: { env.location.isEnabled }, set: { enabled in
                    env.location.isEnabled = enabled
                    if enabled { env.location.requestPermissionIfNeeded() }
                    env.repository?.preferences().locationEnabled = enabled
                    try? env.repository?.save()
                }))
            } header: {
                Text(L("privacy.location"))
            } footer: {
                Text(L("privacy.location.footer"))
            }

            Section {
                Text(L("privacy.dataStatement")).font(.footnote)
                Text(L("privacy.network")).font(.footnote).foregroundStyle(Color.secondary)
                Text(L("privacy.systemBackup")).font(.footnote).foregroundStyle(Color.secondary)
                Text(L("privacy.analytics")).font(.footnote).foregroundStyle(Color.secondary)
            } header: {
                Text(L("privacy.whereData"))
            }

            Section(L("privacy.storage")) {
                LabeledContent(L("privacy.storage.originals"), value: ByteFormatting.string(sizes.originals))
                LabeledContent(L("privacy.storage.reports"), value: ByteFormatting.string(sizes.reports))
                LabeledContent(L("privacy.storage.logos"), value: ByteFormatting.string(sizes.logos))
                LabeledContent(L("privacy.storage.cache"), value: ByteFormatting.string(sizes.cache))
                if let free = sizes.free {
                    LabeledContent(L("privacy.storage.free"), value: ByteFormatting.string(free))
                }
                Button(L("privacy.clearCache")) { confirmClearCache = true }
            }

            Section {
                Button(L("privacy.exportAll")) { backupScope = IdentifiedScope(scope: .all) }
            } footer: {
                Text(L("privacy.exportAll.footer"))
            }

            Section {
                Button(L("privacy.deleteAll"), role: .destructive) { confirmDeleteStep1 = true }
            } footer: {
                Text(L("privacy.deleteAll.footer"))
            }
        }
        .navigationTitle(L("privacy.title"))
        .task(id: env.repository?.revision) { await refreshSizes() }
        .toast($toast)
        .errorAlert($error)
        .sheet(item: $backupScope) { BackupCreateView(scope: $0.scope) }
        .confirmationDialog(L("privacy.clearCache"), isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button(L("privacy.clearCache.confirm")) {
                env.files.clearCaches()
                env.thumbnails.clearMemory()
                toast = ToastMessage(text: L("privacy.clearCache.done"), kind: .success)
                Task { await refreshSizes() }
            }
        } message: {
            Text(L("privacy.clearCache.message"))
        }
        .alert(L("privacy.deleteAll.step1.title"), isPresented: $confirmDeleteStep1) {
            Button(L("common.continue"), role: .destructive) { confirmDeleteStep2 = true }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("privacy.deleteAll.step1.message"))
        }
        .alert(L("privacy.deleteAll.step2.title"), isPresented: $confirmDeleteStep2) {
            Button(L("privacy.deleteAll.confirm"), role: .destructive) {
                Task {
                    do {
                        try await env.deleteAllData()
                        toast = ToastMessage(text: L("privacy.deleteAll.done"), kind: .success)
                        await refreshSizes()
                    } catch {
                        self.error = AppError.wrap(error, default: .databaseSaveFailed)
                    }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("privacy.deleteAll.step2.message"))
        }
    }

    private func refreshSizes() async {
        let files = env.files
        sizes = await Task.detached(priority: .utility) {
            StorageSizes(originals: files.size(of: .originals), reports: files.size(of: .reports), logos: files.size(of: .logos),
                         cache: files.cacheSize, free: files.availableCapacity())
        }.value
    }
}

/// S19 backups: create (Files) and restore with validation, conflicts and a summary.
struct BackupsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var createScope: IdentifiedScope?
    @State private var showImporter = false
    @State private var restore: RestoreState = .idle
    @State private var importCopies: Set<UUID> = []
    @State private var error: AppError?

    enum RestoreState {
        case idle
        case validating
        case review(StagedBackup, [ProjectConflict])
        case restoring
        case done(RestoreSummary)
    }

    var body: some View {
        Form {
            Section {
                Button { createScope = IdentifiedScope(scope: .all) } label: {
                    Label(L("backup.create"), systemImage: "archivebox")
                }
            } footer: {
                Text(L("backup.create.footer"))
            }
            Section {
                Button { showImporter = true } label: { Label(L("backup.restore"), systemImage: "arrow.down.doc") }
                    .disabled(isBusy)
                restoreContent
            } footer: {
                Text(L("backup.restore.footer"))
            }
            Section {
                Text(L("backup.reinstallWarning")).font(.footnote)
                Text(L("backup.purchasesNote")).font(.footnote).foregroundStyle(Color.secondary)
            }
        }
        .navigationTitle(L("backup.title"))
        .sheet(item: $createScope) { BackupCreateView(scope: $0.scope) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await stage(url) } }
        }
        .errorAlert($error)
    }

    private var isBusy: Bool {
        switch restore {
        case .validating, .restoring: return true
        default: return false
        }
    }

    @ViewBuilder private var restoreContent: some View {
        switch restore {
        case .idle:
            EmptyView()
        case .validating:
            HStack { ProgressView(); Text(L("backup.validating")) }
        case .restoring:
            HStack { ProgressView(); Text(L("backup.restoring")) }
        case .review(let staged, let conflicts):
            VStack(alignment: .leading, spacing: 6) {
                Text(L("backup.review.summary", staged.manifest.projects.count, staged.manifest.photos.count, staged.manifest.reports.count))
                    .font(.subheadline)
                Text(L("backup.review.created", staged.manifest.createdAt.appFormatted(date: .abbreviated, time: .shortened)))
                    .font(.footnote).foregroundStyle(Color.secondary)
            }
            ForEach(conflicts) { conflict in
                Toggle(isOn: Binding(get: { importCopies.contains(conflict.backupProjectID) }, set: { value in
                    if value { importCopies.insert(conflict.backupProjectID) } else { importCopies.remove(conflict.backupProjectID) }
                })) {
                    VStack(alignment: .leading) {
                        Text(L("backup.conflict.title", conflict.title))
                        Text(L("backup.conflict.message")).font(.footnote).foregroundStyle(Color.secondary)
                    }
                }
            }
            if !env.entitlements.isPro && staged.manifest.projects.count > 1 {
                Text(L("backup.freeNote")).font(.footnote).foregroundStyle(Color.secondary)
            }
            HStack {
                Button(L("common.cancel")) {
                    try? FileManager.default.removeItem(at: staged.stagingDirectory)
                    restore = .idle
                }
                Spacer()
                Button(L("backup.restore.confirm")) { performRestore(staged) }.buttonStyle(.borderedProminent)
            }
        case .done(let summary):
            Label(L("backup.restored", summary.projects, summary.photos, summary.reports), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
            if summary.skippedProjects > 0 || summary.skippedPhotos > 0 {
                Text(L("backup.skipped", summary.skippedProjects, summary.skippedPhotos)).font(.footnote).foregroundStyle(Color.secondary)
            }
        }
    }

    private func stage(_ url: URL) async {
        guard let repository = env.repository else { return }
        restore = .validating
        importCopies = []
        let files = env.files
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let staged = try await Task.detached(priority: .userInitiated) { () throws -> StagedBackup in
                // Copy first so the picked file can be released; refuses before touching any project.
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try files.ensureSpace(for: size)
                let local = try files.newTempDirectory().appendingPathComponent("backup.zip")
                try FileManager.default.copyItem(at: url, to: local)
                defer { try? FileManager.default.removeItem(at: local) }
                return try BackupService.stage(archiveURL: local, stagingRoot: files.tempRoot, availableBytes: files.availableCapacity())
            }.value
            restore = .review(staged, BackupService.conflicts(in: staged.manifest, repository: repository))
        } catch {
            let appError = AppError.wrap(error, default: .backupInvalidArchive)
            ErrorLog.shared.record(appError.code)
            self.error = appError
            restore = .idle
        }
    }

    private func performRestore(_ staged: StagedBackup) {
        guard let repository = env.repository else { return }
        restore = .restoring
        do {
            let summary = try BackupService.restore(staged, importCopies: importCopies, repository: repository)
            // Restored photos and projects count toward the Free quota like any other data on the device.
            repository.reconcileUsage()
            env.persistFreeSelection()
            env.analytics.track(.backupRestored(photoCount: summary.photos))
            restore = .done(summary)
        } catch {
            let appError = AppError.wrap(error, default: .backupWriteFailed)
            ErrorLog.shared.record(appError.code)
            self.error = appError
            restore = .idle
        }
    }
}

/// Creates a backup archive and hands it to Files. Shows the estimate and a privacy warning first.
struct BackupCreateView: View {
    let scope: BackupScope
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var plan: BackupPlan?
    @State private var planError: AppError?
    @State private var isWriting = false
    @State private var written: (Int64, Int64) = (0, 0)
    @State private var archiveURL: URL?
    @State private var exportRequest: ExportFilesRequest?
    @State private var shareRequest: ShareRequest?
    @State private var error: AppError?
    @State private var flag = CancellationFlag()
    @State private var lease: FileStore.Lease?

    var body: some View {
        NavigationStack {
            Form {
                if let plan {
                    Section {
                        LabeledContent(L("backup.estimate.photos"), value: "\(plan.photoCount)")
                        LabeledContent(L("backup.estimate.projects"), value: "\(plan.manifest.projects.count)")
                        LabeledContent(L("backup.estimate.reports"), value: "\(plan.manifest.reports.count)")
                        LabeledContent(L("backup.estimate.size"), value: ByteFormatting.string(plan.totalBytes))
                        if let free = env.files.availableCapacity() {
                            LabeledContent(L("privacy.storage.free"), value: ByteFormatting.string(free))
                        }
                    }
                    Section {
                        Label(L("backup.warning"), systemImage: "lock.trianglebadge.exclamationmark").font(.footnote)
                    }
                    Section {
                        if let archiveURL {
                            Label(L("backup.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                            Button(L("export.saveFiles")) { exportRequest = ExportFilesRequest(urls: [archiveURL]) }
                            Button(L("export.share")) { shareRequest = ShareRequest(items: [archiveURL], source: .backup) }
                        } else if isWriting {
                            ProgressView(value: Double(written.0), total: Double(max(written.1, 1)))
                                .accessibilityLabel(L("backup.writing"))
                            Button(L("common.cancel"), role: .cancel) { flag.cancel(.user) }
                        } else {
                            Button(L("backup.create.start")) { Task { await write(plan) } }
                        }
                    }
                } else if let planError {
                    Section {
                        Label(planError.displayMessage, systemImage: "exclamationmark.triangle")
                        if planError.code == .backupTooLarge {
                            Text(L("backup.tooLarge.hint")).font(.footnote).foregroundStyle(Color.secondary)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(scope == .all ? L("backup.create") : L("project.downloadFiles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("common.close")) { close() } } }
            .sheet(item: $exportRequest) { request in DocumentExportPicker(urls: request.urls) { _ in } }
            .sheet(item: $shareRequest) { request in ShareSheet(items: request.items) }
            .errorAlert($error)
        }
        .interactiveDismissDisabled(isWriting)
        .onAppear {
            guard plan == nil, planError == nil, let repository = env.repository else { return }
            do { plan = try BackupService.plan(scope: scope, repository: repository) }
            catch { planError = AppError.wrap(error, default: .backupWriteFailed) }
        }
    }

    private func write(_ plan: BackupPlan) async {
        guard !isWriting, archiveURL == nil else { return }
        isWriting = true
        flag = CancellationFlag()
        let flag = self.flag
        let files = env.files
        // Stable snapshot: files of the backup cannot be deleted until it is written.
        let lease = files.lease(plan.filePaths)
        self.lease = lease
        defer {
            files.endLease(lease)
            self.lease = nil
            isWriting = false
        }
        do {
            let url = try files.newTempDirectory().appendingPathComponent(plan.archiveName)
            try await Task.detached(priority: .userInitiated) {
                try BackupService.writeArchive(plan, files: files, to: url, progress: { done, total in
                    Task { @MainActor in written = (done, total) }
                }, isCancelled: { flag.isCancelled })
            }.value
            archiveURL = url
            env.analytics.track(.backupCreated(photoCount: plan.photoCount))
        } catch {
            let appError = AppError.wrap(error, default: .backupWriteFailed)
            if appError.code != .reportCancelled {
                ErrorLog.shared.record(appError.code)
                self.error = appError
            }
        }
    }

    private func close() {
        if let archiveURL { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        dismiss()
    }
}
