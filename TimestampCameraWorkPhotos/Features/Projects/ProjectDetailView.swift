import PhotosUI
import SwiftData
import SwiftUI

/// S08 project: photo grid, pairs and reports of one project.
struct ProjectDetailView: View {
    enum DetailTab: Hashable {
        case photos
        case pairs
        case reports
    }

    let projectID: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var projects: [Project]
    @Query private var photos: [PhotoRecord]
    @Query private var pairs: [PhotoPair]
    @Query private var reports: [ReportVersion]

    @State private var tab: DetailTab = .photos
    @State private var isSelecting = false
    @State private var selection: [UUID] = []
    @State private var showEdit = false
    @State private var showReorder = false
    @State private var reportRequest: ReportRequest?
    @State private var pairRequest: PairRequest?
    @State private var paywallTrigger: PaywallTrigger?
    @State private var showImportPicker = false
    @State private var showImportLimits = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importSession: ImportSession?
    @State private var moveRequest: [UUID]?
    @State private var exportRequest: PhotoExportRequest?
    @State private var backupRequest: BackupScope?
    @State private var deleteRequest: [UUID]?
    @State private var confirmDeleteProject = false
    @State private var confirmSwitchFree = false
    @State private var error: AppError?
    @State private var toast: ToastMessage?
    @State private var lookingUpAddresses = false

    init(projectID: UUID) {
        self.projectID = projectID
        let pid: UUID? = projectID
        let saved = SaveState.saved.rawValue
        let missing = SaveState.missingFile.rawValue
        _projects = Query(filter: #Predicate<Project> { $0.id == projectID })
        _photos = Query(filter: #Predicate<PhotoRecord> {
            $0.projectID == pid && ($0.saveStateRaw == saved || $0.saveStateRaw == missing)
        }, sort: [SortDescriptor(\PhotoRecord.order), SortDescriptor(\PhotoRecord.createdAt)])
        _pairs = Query(filter: #Predicate<PhotoPair> { $0.projectID == projectID },
                       sort: [SortDescriptor(\PhotoPair.order), SortDescriptor(\PhotoPair.createdAt)])
        _reports = Query(filter: #Predicate<ReportVersion> { $0.projectID == projectID },
                         sort: [SortDescriptor(\ReportVersion.createdAt, order: .reverse)])
    }

    private var project: Project? { projects.first }

    var body: some View {
        if let project {
            content(project)
        } else {
            ContentUnavailableView(L("project.notFound"), systemImage: "folder.badge.questionmark")
        }
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        let policy = env.policy()
        let access = policy.access(for: project.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(project)
                banner(project, policy: policy, access: access)
                Picker(L("project.section"), selection: $tab) {
                    Text(L("project.tab.photos", photos.count)).tag(DetailTab.photos)
                    Text(L("project.tab.pairs", pairs.count)).tag(DetailTab.pairs)
                    Text(L("project.tab.reports", reports.count)).tag(DetailTab.reports)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("project.tabs")
                switch tab {
                case .photos:
                    photosSection(project, access: access)
                case .pairs:
                    PairsListSection(project: project, pairs: pairs, photos: photos, canEdit: access.canEdit) { request in
                        pairRequest = request
                    }
                case .reports:
                    ReportsListSection(project: project, reports: reports, photosCount: photos.count, canCreate: !photos.isEmpty) {
                        reportTapped(project, preselected: [])
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
        }
        .background(Theme.groupedBackground)
        .navigationTitle(project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(project, policy: policy, access: access) }
        .safeAreaInset(edge: .bottom) { bottomBar(project, access: access) }
        .toast($toast)
        .errorAlert($error)
        .sheet(isPresented: $showEdit) { ProjectEditView(project: project) }
        .sheet(isPresented: $showReorder) { ReorderPhotosView(projectID: project.id) }
        .sheet(item: $reportRequest) { request in ReportFlowView(project: request.project, preselected: request.preselected) }
        .sheet(item: $pairRequest) { request in PairEditView(project: project, pairID: request.pairID, before: request.before, after: request.after) }
        .sheet(item: $paywallTrigger) { PaywallView(trigger: $0) }
        .sheet(item: $importSession) { ImportProgressView(session: $0) }
        .sheet(item: Binding(get: { moveRequest.map(IdentifiedIDs.init) }, set: { moveRequest = $0?.ids })) { request in
            MoveToProjectSheet(photoIDs: request.ids, currentProjectID: project.id) { finishSelection() }
        }
        .sheet(item: $exportRequest) { request in PhotoExportSheet(request: request) }
        .sheet(item: Binding(get: { backupRequest.map(IdentifiedScope.init) }, set: { backupRequest = $0?.scope })) { item in
            BackupCreateView(scope: item.scope)
        }
        .photosPicker(isPresented: $showImportPicker, selection: $pickerItems,
                      maxSelectionCount: max(1, min(AccessPolicy.importBatchLimit, policy.remainingPhotoSlots(for: project.id))),
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickerItems) { _, items in startImport(items, project: project) }
        .modifier(ImportLimitsDialog(isPresented: $showImportLimits, remaining: policy.shownRemainingPhotoSlots(for: project.id)) {
            showImportPicker = true
        })
        .modifier(DeletePhotosDialog(photoIDs: $deleteRequest) { finishSelection() })
        .confirmationDialog(L("project.delete.title"), isPresented: $confirmDeleteProject, titleVisibility: .visible) {
            Button(L("project.delete.backupFirst")) { backupRequest = .project(project.id) }
            Button(L("project.delete.confirm", photos.count), role: .destructive) { deleteProject(project) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("project.delete.message", photos.count, reports.count))
        }
        .confirmationDialog(L("free.switch.title"), isPresented: $confirmSwitchFree, titleVisibility: .visible) {
            Button(L("free.switch.confirm")) {
                do { try env.repository?.selectFreeProject(project.id) } catch { self.error = AppError.wrap(error, default: .databaseSaveFailed) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("free.switch.message"))
        }
    }

    // MARK: Header and banners

    @ViewBuilder
    private func header(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !project.siteAddress.isEmpty {
                Label(project.siteAddress, systemImage: "mappin.and.ellipse").font(.subheadline)
            }
            if !project.clientName.isEmpty {
                Label(project.clientName, systemImage: "person").font(.subheadline)
            }
            if let workDate = project.workDate {
                Label(DateTimeFormatting(locale: AppLanguage.current.formattingLocale).workDateString(workDate), systemImage: "calendar").font(.subheadline)
            }
        }
        .foregroundStyle(Color.secondary)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func banner(_ project: Project, policy: AccessPolicy, access: AccessPolicy.ProjectAccess) -> some View {
        if env.entitlements.isDetermined {
            switch access {
            case .archived:
                InfoBanner(icon: "archivebox", title: L("project.archived.banner.title"), message: L("project.archived.banner.message"),
                           actions: [(L("project.unarchive"), { setArchived(project, false) })])
            case .readOnlyNotSelected:
                InfoBanner(icon: "lock", title: L("project.readOnly.title"), message: L("project.readOnly.notSelected"),
                           tint: Theme.warning,
                           actions: readOnlyActions(project, policy: policy))
            case .readOnlyTooManyPhotos:
                InfoBanner(icon: "lock", title: L("project.readOnly.title"),
                           message: L("project.readOnly.tooMany", photos.count, AccessPolicy.freePhotoLimit), tint: Theme.warning,
                           actions: readOnlyActions(project, policy: policy))
            case .editable:
                if !policy.isPro {
                    if policy.isFreePhotoQuotaUsedUp {
                        InfoBanner(icon: "photo.stack", title: L("free.photosUsedUp.title"),
                                   message: L("free.photosUsedUp.message", policy.photoQuota),
                                   actions: [(L("paywall.seePro"), { paywallTrigger = .freePhotos })])
                    } else if photos.count >= AccessPolicy.freePhotoLimit {
                        InfoBanner(icon: "photo.stack", title: L("project.freeUsage", photos.count, AccessPolicy.freePhotoLimit),
                                   message: L("project.freeUsage.full"),
                                   actions: [(L("paywall.seePro"), { paywallTrigger = .photoLimit })])
                    } else {
                        InfoBanner(icon: "photo.stack", title: L("free.photosLeft", policy.remainingFreePhotos),
                                   message: L("free.quota.note"))
                    }
                }
            }
        }
    }

    private func readOnlyActions(_ project: Project, policy: AccessPolicy) -> [(String, () -> Void)] {
        var actions: [(String, () -> Void)] = []
        if policy.canSelectAsFreeProject(project.id) {
            actions.append((L("free.switch.action"), { confirmSwitchFree = true }))
        }
        actions.append((L("project.downloadFiles"), { backupRequest = .project(project.id) }))
        actions.append((L("paywall.seePro"), { paywallTrigger = .secondProject }))
        return actions
    }

    // MARK: Photos

    @ViewBuilder
    private func photosSection(_ project: Project, access: AccessPolicy.ProjectAccess) -> some View {
        if photos.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(L("project.photos.empty.title"), systemImage: "camera",
                                       description: Text(L("project.photos.empty.message")))
                if access.canEdit {
                    HStack {
                        Button(L("project.takePhotos")) { openCamera(project) }.buttonStyle(.borderedProminent)
                        Button(L("project.importPhotos")) { importTapped(project) }.buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            let roles = pairRoles
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    let cell = PhotoCell(photo: photo, index: index + 1, pairRole: roles[photo.id],
                                         isSelected: selection.contains(photo.id), isSelecting: isSelecting)
                    if isSelecting {
                        Button { toggle(photo.id) } label: { cell }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: ProjectsRoute.photo(photo.id)) { cell }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("photo.cell")
                    }
                }
            }
        }
    }

    private var pairRoles: [UUID: String] {
        var roles: [UUID: String] = [:]
        for pair in pairs {
            if let before = pair.beforePhotoID { roles[before] = L("pair.role.beforeShort") }
            if let after = pair.afterPhotoID { roles[after] = L("pair.role.afterShort") }
        }
        return roles
    }

    private func toggle(_ id: UUID) {
        if let index = selection.firstIndex(of: id) { selection.remove(at: index) } else { selection.append(id) }
    }

    private func finishSelection() {
        selection = []
        isSelecting = false
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ project: Project, policy: AccessPolicy, access: AccessPolicy.ProjectAccess) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isSelecting {
                Button(L("common.done")) { finishSelection() }
            } else {
                Menu {
                    if access.canEdit {
                        Button { openCamera(project) } label: { Label(L("project.takePhotos"), systemImage: "camera") }
                        Button { importTapped(project) } label: { Label(L("project.importPhotos"), systemImage: "photo.on.rectangle") }
                        Button { pairRequest = PairRequest(pairID: nil, before: nil, after: nil) } label: {
                            Label(L("pairs.new"), systemImage: "rectangle.split.2x1")
                        }
                        .disabled(photos.count < 2)
                    }
                    Button { reportTapped(project, preselected: []) } label: {
                        Label(L("report.create"), systemImage: "doc.richtext")
                    }
                    .disabled(photos.isEmpty)
                } label: {
                    Label(L("common.add"), systemImage: "plus")
                }
                Menu {
                    Button { isSelecting = true; tab = .photos } label: { Label(L("common.select"), systemImage: "checkmark.circle") }
                        .disabled(photos.isEmpty)
                    if access.canEdit {
                        Button { showEdit = true } label: { Label(L("project.edit.title"), systemImage: "pencil") }
                        Menu {
                            Button(L("sort.captureDate")) { sort(project, .captureDate) }
                            Button(L("sort.added")) { sort(project, .added) }
                            Button(L("sort.manual")) { showReorder = true }
                        } label: { Label(L("sort.title"), systemImage: "arrow.up.arrow.down") }
                        Button { lookUpAddresses(project) } label: {
                            Label(L("project.lookUpAddresses"), systemImage: "mappin.circle")
                        }
                        .disabled(lookingUpAddresses)
                    }
                    Button { backupRequest = .project(project.id) } label: {
                        Label(L("project.downloadFiles"), systemImage: "square.and.arrow.down.on.square")
                    }
                    if policy.canSelectAsFreeProject(project.id) {
                        Button { confirmSwitchFree = true } label: { Label(L("free.switch.action"), systemImage: "star") }
                    }
                    if project.isArchived {
                        Button { setArchived(project, false) } label: { Label(L("project.unarchive"), systemImage: "tray.and.arrow.up") }
                    } else {
                        Button { setArchived(project, true) } label: { Label(L("project.archive"), systemImage: "archivebox") }
                    }
                    Button(role: .destructive) { confirmDeleteProject = true } label: {
                        Label(L("project.delete.title"), systemImage: "trash")
                    }
                } label: {
                    Label(L("common.more"), systemImage: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func bottomBar(_ project: Project, access: AccessPolicy.ProjectAccess) -> some View {
        if isSelecting {
            VStack(spacing: 6) {
                Text(L("selection.count", selection.count)).font(.footnote).foregroundStyle(Color.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        selectionButton(L("report.create"), "doc.richtext") {
                            reportTapped(project, preselected: selection)
                        }
                        if access.canEdit {
                            selectionButton(L("pairs.make"), "rectangle.split.2x1", enabled: selection.count == 2) {
                                pairRequest = PairRequest(pairID: nil, before: selection.first, after: selection.last)
                            }
                            selectionButton(L("photo.move"), "folder") { moveRequest = selection }
                            selectionButton(L("stamp.applyDefault"), "textformat.size") { applyDefaultStamp() }
                        } else if !project.isArchived {
                            // Moving out of a read-only project is allowed (no data loss).
                            selectionButton(L("photo.move"), "folder") { moveRequest = selection }
                        }
                        selectionButton(L("photo.export"), "square.and.arrow.up") {
                            exportRequest = PhotoExportRequest(photoIDs: selection, projectTitle: project.displayTitle)
                        }
                        if !project.isArchived {
                            selectionButton(L("common.delete"), "trash", role: .destructive) { deleteRequest = selection }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
            .background(.bar)
            .disabled(selection.isEmpty)
        } else if tab == .photos && !photos.isEmpty {
            Button { reportTapped(project, preselected: []) } label: {
                Label(L("report.create"), systemImage: "doc.richtext")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("project.createReport")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func selectionButton(_ title: String, _ icon: String, enabled: Bool = true, role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: Theme.minTapSize)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }

    // MARK: Actions

    /// New reports need an editable project; read-only/archived projects keep their saved PDFs.
    private func reportTapped(_ project: Project, preselected: [UUID]) {
        switch env.policy().access(for: project.id) {
        case .editable:
            reportRequest = ReportRequest(project: project, preselected: preselected)
        case .archived:
            error = AppError(.projectArchived)
        case .readOnlyNotSelected, .readOnlyTooManyPhotos:
            paywallTrigger = .secondProject
        }
    }

    private func openCamera(_ project: Project) {
        guard let repository = env.repository else { return }
        repository.preferences().cameraProjectID = project.id
        try? repository.save()
        env.router.openCamera()
    }

    private func importTapped(_ project: Project) {
        let policy = env.policy()
        guard policy.access(for: project.id) == .editable else { return }
        if policy.isFreePhotoQuotaUsedUp {
            paywallTrigger = .freePhotos
            return
        }
        if policy.remainingPhotoSlots(for: project.id) <= 0 {
            if policy.isPro { toast = ToastMessage(text: L("camera.full.pro", AccessPolicy.proPhotoLimit), kind: .error) }
            else { paywallTrigger = .photoLimit }
            return
        }
        pickerItems = []
        let remaining = policy.shownRemainingPhotoSlots(for: project.id)
        if ImportLimitsDialog.shouldShow(remaining: remaining) { showImportLimits = true } else { showImportPicker = true }
    }

    private func startImport(_ items: [PhotosPickerItem], project: Project) {
        guard !items.isEmpty, let repository = env.repository else { return }
        let projectID = project.id
        let session = ImportSession(projectID: projectID, pickerItems: items, repository: repository, files: env.files,
                                    analytics: env.analytics) { [env] in env.policy().remainingPhotoSlots(for: projectID) }
        importSession = session
        session.start()
        pickerItems = []
    }

    private func sort(_ project: Project, _ mode: PhotoSortMode) {
        do { try env.repository?.sort(projectID: project.id, mode: mode) } catch { self.error = AppError.wrap(error, default: .databaseSaveFailed) }
    }

    private func setArchived(_ project: Project, _ archived: Bool) {
        do {
            try env.repository?.setArchived(project, archived: archived)
            env.persistFreeSelection()
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }

    private func deleteProject(_ project: Project) {
        do {
            try env.repository?.deleteProject(project)
            env.persistFreeSelection()
            dismiss()
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }

    private func applyDefaultStamp() {
        guard let repository = env.repository else { return }
        do {
            try repository.applyStamp(repository.preferences().defaultStamp, to: repository.photos(ids: selection))
            toast = ToastMessage(text: L("stamp.applied", selection.count), kind: .success)
            finishSelection()
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }

    private func lookUpAddresses(_ project: Project) {
        guard let capture = env.capture else { return }
        lookingUpAddresses = true
        Task {
            let count = await capture.lookUpMissingAddresses(projectID: project.id)
            lookingUpAddresses = false
            toast = ToastMessage(text: count == 0 ? L("project.lookUpAddresses.none") : L("project.lookUpAddresses.done", count),
                                 kind: .info)
        }
    }
}

struct ReportRequest: Identifiable {
    let id = UUID()
    let project: Project
    let preselected: [UUID]
}

struct PairRequest: Identifiable {
    let id = UUID()
    let pairID: UUID?
    let before: UUID?
    let after: UUID?
}

struct PhotoExportRequest: Identifiable {
    let id = UUID()
    let photoIDs: [UUID]
    let projectTitle: String?
}

struct IdentifiedIDs: Identifiable {
    let id = UUID()
    let ids: [UUID]
}

struct IdentifiedScope: Identifiable {
    let id = UUID()
    let scope: BackupScope
}

/// DATA-04 delete: confirmation; offers to delete local reports that contain the photos and explains
/// that copies already sent cannot be recalled.
struct DeletePhotosDialog: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var photoIDs: [UUID]?
    var onDone: () -> Void

    func body(content: Content) -> some View {
        let ids = photoIDs ?? []
        let relatedReports = env.repository?.reportsIncluding(photoIDs: ids) ?? []
        content.confirmationDialog(L("photo.delete.title", ids.count),
                                   isPresented: Binding(get: { photoIDs != nil }, set: { if !$0 { photoIDs = nil } }),
                                   titleVisibility: .visible) {
            Button(L("photo.delete.confirm", ids.count), role: .destructive) { delete(ids, reports: []) }
            if !relatedReports.isEmpty {
                Button(L("photo.delete.withReports", relatedReports.count), role: .destructive) { delete(ids, reports: relatedReports) }
            }
            Button(L("common.cancel"), role: .cancel) { photoIDs = nil }
        } message: {
            Text(relatedReports.isEmpty ? L("photo.delete.message") : L("photo.delete.messageReports", relatedReports.count))
        }
    }

    private func delete(_ ids: [UUID], reports: [ReportVersion]) {
        guard let repository = env.repository else { return }
        try? repository.deletePhotos(repository.photos(ids: ids), alsoDeleteReports: reports)
        for id in ids { env.thumbnails.invalidate(id) }
        env.persistFreeSelection()
        photoIDs = nil
        onDone()
    }
}
