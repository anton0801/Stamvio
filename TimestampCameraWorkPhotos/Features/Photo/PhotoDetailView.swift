import SwiftData
import SwiftUI

/// S09 photo: original / stamped result, caption, pair role, sources of date and place, export, delete.
struct PhotoDetailView: View {
    let photoID: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [PhotoRecord]

    @State private var showStamped = true
    @State private var caption = ""
    @State private var shortCaption = ""
    @State private var loadedFor: UUID?
    @State private var previewImage: CGImage?
    @State private var showManualDate = false
    @State private var showManualLocation = false
    @State private var showStampEditor = false
    @State private var exportRequest: PhotoExportRequest?
    @State private var moveRequest: [UUID]?
    @State private var deleteRequest: [UUID]?
    @State private var pairRequest: PairRequest?
    @State private var error: AppError?
    @State private var toast: ToastMessage?

    init(photoID: UUID) {
        self.photoID = photoID
        _records = Query(filter: #Predicate<PhotoRecord> { $0.id == photoID })
    }

    private var photo: PhotoRecord? { records.first }

    var body: some View {
        if let photo {
            content(photo)
        } else {
            ContentUnavailableView(L("photo.notFound"), systemImage: "photo")
        }
    }

    private func canEdit(_ photo: PhotoRecord) -> Bool {
        guard let projectID = photo.projectID else { return true }
        return env.policy().access(for: projectID) == .editable
    }

    @ViewBuilder
    private func content(_ photo: PhotoRecord) -> some View {
        let editable = canEdit(photo)
        let project = env.repository?.project(id: photo.projectID)
        Form {
            Section {
                imageSection(photo, project: project)
            }
            if photo.saveState == .missingFile {
                Section {
                    Label(L("photo.missingFile.message"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.destructive)
                }
            }
            if !editable {
                Section {
                    Label(project?.isArchived == true ? L("project.archived.banner.message") : L("project.readOnly.notSelected"),
                          systemImage: "lock")
                        .font(.footnote)
                }
            }
            captionSection(photo, editable: editable)
            dateSection(photo, editable: editable)
            locationSection(photo, project: project, editable: editable)
            if let project { pairSection(photo, project: project, editable: editable) }
            stampSection(photo, editable: editable)
            actionsSection(photo, editable: editable, project: project)
            infoSection(photo)
        }
        .navigationTitle(L("photo.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { exportRequest = PhotoExportRequest(photoIDs: [photo.id], projectTitle: project?.displayTitle) } label: {
                    Label(L("photo.export"), systemImage: "square.and.arrow.up")
                }
                .disabled(photo.saveState == .missingFile)
            }
        }
        .toast($toast)
        .errorAlert($error)
        .onAppear { load(photo) }
        .onDisappear { saveCaption() }
        .task(id: photo.id) {
            let files = env.files
            let path = photo.originalPath
            previewImage = await Task.detached(priority: .userInitiated) {
                guard let url = try? files.url(forRelative: path) else { return nil }
                return ImageLoader.orientedImage(url: url, maxPixel: 1600)
            }.value
        }
        .sheet(isPresented: $showManualDate) { ManualDateSheet(photo: photo) }
        .sheet(isPresented: $showManualLocation) { ManualLocationSheet(photo: photo) }
        .sheet(isPresented: $showStampEditor) { PhotoStampEditor(photo: photo, previewImage: previewImage, projectTitle: project?.displayTitle) }
        .sheet(item: $exportRequest) { PhotoExportSheet(request: $0) }
        .sheet(item: Binding(get: { moveRequest.map(IdentifiedIDs.init) }, set: { moveRequest = $0?.ids })) { request in
            MoveToProjectSheet(photoIDs: request.ids, currentProjectID: photo.projectID) {}
        }
        .sheet(item: $pairRequest) { request in
            if let project { PairEditView(project: project, pairID: request.pairID, before: request.before, after: request.after) }
        }
        .modifier(DeletePhotosDialog(photoIDs: $deleteRequest) { dismiss() })
    }

    // MARK: Sections

    @ViewBuilder
    private func imageSection(_ photo: PhotoRecord, project: Project?) -> some View {
        VStack(spacing: 10) {
            Picker(L("photo.view"), selection: $showStamped) {
                Text(L("photo.view.stamped")).tag(true)
                Text(L("photo.view.original")).tag(false)
            }
            .pickerStyle(.segmented)
            if let previewImage {
                if showStamped {
                    StampPreviewImage(settings: photo.stamp?.settings ?? StampSettings.default,
                                      input: stampInput(photo, project: project), baseImage: previewImage)
                } else {
                    Image(uiImage: UIImage(cgImage: previewImage))
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(L("photo.view.original.a11y"))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            Text(L("photo.originalKept")).font(.caption).foregroundStyle(Color.secondary)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
    }

    private func stampInput(_ photo: PhotoRecord, project: Project?) -> StampInput {
        StampInput(dateInfo: photo.dateInfo, isImported: photo.isImported, projectTitle: project?.displayTitle,
                   location: photo.location, shortCaption: shortCaption.isEmpty ? StampText.shortened(caption, limit: TextLimits.stampCaption) : shortCaption)
    }

    @ViewBuilder
    private func captionSection(_ photo: PhotoRecord, editable: Bool) -> some View {
        Section {
            LimitedTextField(L("photo.caption.placeholder"), text: $caption, limit: TextLimits.caption, axis: .vertical, lines: 2...6)
                .disabled(!editable)
            if caption.count > TextLimits.stampCaption || !shortCaption.isEmpty {
                LimitedTextField(L("photo.shortCaption.placeholder"), text: $shortCaption, limit: TextLimits.stampCaption, axis: .vertical)
                    .disabled(!editable)
            }
        } header: {
            Text(L("photo.caption"))
        } footer: {
            Text(caption.count > TextLimits.stampCaption ? L("photo.caption.longFooter", TextLimits.stampCaption) : L("photo.caption.footer"))
        }
        .onChange(of: caption) { _, _ in scheduleCaptionSave() }
        .onChange(of: shortCaption) { _, _ in scheduleCaptionSave() }
    }

    @ViewBuilder
    private func dateSection(_ photo: PhotoRecord, editable: Bool) -> some View {
        let strings = LocalizedStrings(language: .current)
        let formatting = DateTimeFormatting(locale: AppLanguage.current.formattingLocale, includeSeconds: true)
        Section(L("photo.date")) {
            LabeledContent(L("photo.date.shown"), value: ProvenanceText.time(photo.dateInfo, isImported: photo.isImported,
                                                                          strings: strings, formatting: formatting))
            if photo.hasManualDate {
                LabeledContent(L("photo.date.original"), value: ProvenanceText.time(photo.originalDateInfo, isImported: photo.isImported,
                                                                                  strings: strings, formatting: formatting))
            }
            if let raw = photo.captureRaw {
                LabeledContent(L("photo.date.raw"), value: raw)
            }
            if let tz = photo.captureTimeZoneID, photo.dateSource == .device {
                LabeledContent(L("photo.date.timeZone"), value: tz)
            }
            if let importedAt = photo.importedAt {
                LabeledContent(L("photo.date.importedAt"), value: importedAt.appFormatted(date: .abbreviated, time: .shortened))
            }
            if editable {
                Button(photo.hasManualDate ? L("photo.date.editManual") : L("photo.date.setManual")) { showManualDate = true }
                if photo.hasManualDate {
                    Button(L("photo.date.removeManual"), role: .destructive) {
                        do { try env.repository?.clearManualDate(photo) } catch { self.error = AppError.wrap(error, default: .databaseSaveFailed) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func locationSection(_ photo: PhotoRecord, project: Project?, editable: Bool) -> some View {
        let strings = LocalizedStrings(language: .current)
        let location = photo.location
        Section {
            if let location, !location.isEmpty || location.fixStatus != .notRequested {
                if let address = location.displayAddress {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(address)
                        Text(ProvenanceText.locationLabel(location, strings: strings)).font(.footnote).foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let coordinates = CoordinateFormatting.string(location) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinates).font(.callout.monospacedDigit())
                        Text(ProvenanceText.coordinateLabel(location, strings: strings)).font(.footnote).foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if location.displayAddressKind == .manual, let original = location.addressOriginal {
                    LabeledContent(L("photo.location.automatic"), value: original)
                }
                statusLine(location)
            } else {
                Text(photo.isImported ? L("photo.location.noneImported") : L("photo.location.none")).foregroundStyle(Color.secondary)
            }
            if editable {
                if let location, location.hasCoordinates, location.addressStatus != .pending, location.addressOriginal == nil {
                    Button(L("photo.location.lookUp")) { Task { await env.capture?.lookUpAddress(photoID: photo.id) } }
                }
                Button(location?.displayAddressKind == .manual ? L("photo.location.editManual") : L("photo.location.setManual")) {
                    showManualLocation = true
                }
                if let project, !project.siteAddress.isEmpty, location?.displayAddressKind != .project {
                    Button(L("photo.location.useProject")) {
                        do { try env.repository?.setAddressOverride(photo, text: project.siteAddress, kind: .project) }
                        catch { self.error = AppError.wrap(error, default: .databaseSaveFailed) }
                    }
                }
                if location?.addressOverride != nil {
                    Button(L("photo.location.removeOverride"), role: .destructive) {
                        do { try env.repository?.clearAddressOverride(photo) } catch { self.error = AppError.wrap(error, default: .databaseSaveFailed) }
                    }
                }
            }
        } header: {
            Text(L("photo.location"))
        } footer: {
            Text(photo.isImported ? L("photo.location.footerImported") : L("photo.location.footer"))
        }
    }

    @ViewBuilder
    private func statusLine(_ location: PhotoLocation) -> some View {
        switch location.fixStatus {
        case .waiting:
            HStack { ProgressView(); Text(L("photo.location.waiting")).font(.footnote) }
        case .unavailable where !location.hasCoordinates:
            Label(L("photo.location.unavailable"), systemImage: "location.slash").font(.footnote).foregroundStyle(Color.secondary)
        default:
            EmptyView()
        }
        switch location.addressStatus {
        case .pending:
            HStack { ProgressView(); Text(L("photo.location.addressPending")).font(.footnote) }
        case .failed:
            Label(L("photo.location.addressFailed"), systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(Color.secondary)
        case .noResult:
            Label(L("photo.location.addressNoResult"), systemImage: "questionmark.circle").font(.footnote).foregroundStyle(Color.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func pairSection(_ photo: PhotoRecord, project: Project, editable: Bool) -> some View {
        Section(L("photo.pair")) {
            if let pair = env.repository?.pair(containing: photo.id) {
                let role = pair.beforePhotoID == photo.id ? L("pair.role.before") : L("pair.role.after")
                Button {
                    pairRequest = PairRequest(pairID: pair.id, before: pair.beforePhotoID, after: pair.afterPhotoID)
                } label: {
                    LabeledContent(role, value: pair.title.isEmpty ? L("pair.untitled") : pair.title)
                }
                .disabled(!editable)
                if !pair.isComplete { Text(L("pair.draft.hint")).font(.footnote).foregroundStyle(Color.secondary) }
            } else if editable {
                Button(L("photo.pair.asBefore")) { pairRequest = PairRequest(pairID: nil, before: photo.id, after: nil) }
                Button(L("photo.pair.asAfter")) { pairRequest = PairRequest(pairID: nil, before: nil, after: photo.id) }
            } else {
                Text(L("photo.pair.none")).foregroundStyle(Color.secondary)
            }
        }
    }

    @ViewBuilder
    private func stampSection(_ photo: PhotoRecord, editable: Bool) -> some View {
        Section {
            LabeledContent(L("stamp.preset"), value: L("stamp.preset.\(photo.stamp?.settings.preset.rawValue ?? StampPreset.compact.rawValue)"))
            if editable {
                Button(L("photo.stamp.edit")) { showStampEditor = true }
            }
        } header: {
            Text(L("photo.stamp"))
        } footer: {
            Text(L("photo.stamp.footer"))
        }
    }

    @ViewBuilder
    private func actionsSection(_ photo: PhotoRecord, editable: Bool, project: Project?) -> some View {
        Section {
            Button { exportRequest = PhotoExportRequest(photoIDs: [photo.id], projectTitle: project?.displayTitle) } label: {
                Label(L("photo.export"), systemImage: "square.and.arrow.up")
            }
            .disabled(photo.saveState == .missingFile)
            if project?.isArchived != true {
                Button { moveRequest = [photo.id] } label: { Label(L("photo.move"), systemImage: "folder") }
                Button(role: .destructive) { deleteRequest = [photo.id] } label: { Label(L("common.delete"), systemImage: "trash") }
            }
        }
    }

    @ViewBuilder
    private func infoSection(_ photo: PhotoRecord) -> some View {
        Section(L("photo.info")) {
            LabeledContent(L("photo.info.source"), value: sourceText(photo))
            LabeledContent(L("photo.info.format"), value: photo.format.displayName)
            let size = ImageGeometry.orientedSize(width: photo.pixelWidth, height: photo.pixelHeight, orientation: photo.orientation)
            LabeledContent(L("photo.info.dimensions"), value: "\(Int(size.width)) × \(Int(size.height))")
            LabeledContent(L("photo.info.size"), value: ByteFormatting.string(photo.byteSize))
            LabeledContent(L("photo.info.sha256"), value: String(photo.sha256.prefix(16)) + "…")
                .accessibilityHint(L("photo.info.sha256.hint"))
        }
    }

    private func sourceText(_ photo: PhotoRecord) -> String {
        switch photo.source {
        case .capture: return L("photo.source.capture")
        case .import: return L("photo.source.import")
        case .recovered: return L("photo.source.recovered")
        }
    }

    // MARK: Caption saving

    private func load(_ photo: PhotoRecord) {
        guard loadedFor != photo.id else { return }
        caption = photo.caption
        shortCaption = photo.stamp?.customShortCaption ?? ""
        loadedFor = photo.id
    }

    @State private var saveTask: Task<Void, Never>?

    private func scheduleCaptionSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveCaption()
        }
    }

    private func saveCaption() {
        guard let photo, loadedFor == photo.id, canEdit(photo) else { return }
        let currentShort = photo.stamp?.customShortCaption ?? ""
        guard caption != photo.caption || shortCaption != currentShort else { return }
        do {
            try env.repository?.updateCaption(photo, caption: caption, shortCaption: shortCaption)
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }
}

/// Manual date: stored separately with its own time; the original stays unchanged and the photo is
/// marked "Manual date" everywhere.
struct ManualDateSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoRecord
    @State private var date = Date()
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(L("photo.date.manualPicker"), selection: $date)
                        .datePickerStyle(.graphical)
                } footer: {
                    Text(L("photo.date.manualFooter", TimeZone.current.identifier))
                }
            }
            .navigationTitle(L("photo.date.setManual"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        do {
                            try env.repository?.setManualDate(photo, date: date)
                            dismiss()
                        } catch {
                            self.error = AppError.wrap(error, default: .databaseSaveFailed)
                        }
                    }
                }
            }
            .errorAlert($error)
        }
        .onAppear {
            if let local = photo.dateInfo.local {
                let offset = photo.dateInfo.offsetSeconds ?? TimeZone.current.secondsFromGMT()
                date = local.instant(offsetSeconds: offset)
            }
        }
    }
}

/// Manual location label: marked "Manual location"; it never creates coordinates.
struct ManualLocationSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoRecord
    @State private var text = ""
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LimitedTextField(L("location.manual.placeholder"), text: $text, limit: TextLimits.manualAddress, axis: .vertical)
                } footer: {
                    Text(L("photo.location.manualFooter"))
                }
            }
            .navigationTitle(L("photo.location.setManual"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        do {
                            try env.repository?.setAddressOverride(photo, text: text, kind: .manual)
                            dismiss()
                        } catch {
                            self.error = AppError.wrap(error, default: .databaseSaveFailed)
                        }
                    }
                }
            }
            .errorAlert($error)
        }
        .onAppear {
            if photo.location?.addressOverrideKind == .manual { text = photo.location?.addressOverride ?? "" }
            else { text = photo.location?.addressOriginal ?? "" }
        }
    }
}

/// Stamp of one photo. Changing it never changes the original file.
struct PhotoStampEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoRecord
    let previewImage: CGImage?
    let projectTitle: String?
    @State private var settings = StampSettings.default
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            Form {
                StampSettingsEditor(settings: $settings,
                                    previewInput: StampInput(dateInfo: photo.dateInfo, isImported: photo.isImported,
                                                             projectTitle: projectTitle, location: photo.location,
                                                             shortCaption: photo.stampCaption),
                                    previewImage: previewImage)
            }
            .navigationTitle(L("photo.stamp.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        do {
                            try env.repository?.updateStamp(photo, settings: settings)
                            dismiss()
                        } catch {
                            self.error = AppError.wrap(error, default: .databaseSaveFailed)
                        }
                    }
                }
            }
            .errorAlert($error)
        }
        .onAppear { settings = photo.stamp?.settings ?? env.repository?.preferences().defaultStamp ?? .default }
    }
}
