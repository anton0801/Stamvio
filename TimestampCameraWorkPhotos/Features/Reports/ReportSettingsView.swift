import SwiftData
import SwiftUI

/// Sheet that walks through S11 settings → S13 generation → S12 PDF.
struct ReportFlowView: View {
    let project: Project
    let preselected: [UUID]
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var job: ReportGenerationJob?
    @State private var settings: ReportSettings?

    var body: some View {
        NavigationStack {
            if let job {
                ReportGenerationView(job: job, onEdit: { self.job = nil }, onDone: { dismiss() })
            } else {
                ReportSettingsView(project: project, preselected: preselected, settings: $settings) { job in
                    // A second fast tap on Generate never starts a second job.
                    guard self.job == nil else { return }
                    self.job = job
                    job.start()
                }
            }
        }
        .interactiveDismissDisabled(job?.isRunning == true)
    }
}

/// S11 report settings: items, template, language, A4/Letter, privacy of locations, title and summary.
struct ReportSettingsView: View {
    let project: Project
    let preselected: [UUID]
    @Binding var settings: ReportSettings?
    let onGenerate: (ReportGenerationJob) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ReportSettings()
    @State private var loaded = false
    @State private var paywallTrigger: PaywallTrigger?
    @State private var error: AppError?
    @State private var showItems = false

    var body: some View {
        let policy = env.policy()
        let photos = env.repository?.photos(projectID: project.id).filter { $0.saveState == .saved } ?? []
        let pairs = env.repository?.pairs(projectID: project.id) ?? []
        let completePairs = pairs.filter(\.isComplete)
        Form {
            Section {
                Picker(L("report.template"), selection: $draft.template) {
                    Text(L("report.template.standard")).tag(ReportTemplate.standard)
                    Text(L("report.template.beforeAfter") + (policy.isPro ? "" : " · Pro")).tag(ReportTemplate.beforeAfter)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("report.template")
                if draft.template == .beforeAfter && !policy.isPro {
                    Label(L("report.beforeAfter.previewHint"), systemImage: "star").font(.footnote)
                }
            } footer: {
                Text(draft.template == .standard ? L("report.template.standard.footer") : L("report.template.beforeAfter.footer"))
            }

            Section {
                Button { showItems = true } label: {
                    LabeledContent(draft.template == .standard ? L("report.items.photos") : L("report.items.pairs"),
                                   value: itemsSummary(photos: photos, completePairs: completePairs, allPairs: pairs))
                }
                if draft.template == .beforeAfter {
                    let excludedDrafts = pairs.count - completePairs.count
                    let unpaired = photos.filter { photo in !pairs.contains { $0.contains(photo.id) } }.count
                    Text(L("report.pairs.status", completePairs.count, excludedDrafts, unpaired))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                if let limitMessage = limitMessage(policy: policy) {
                    Label(limitMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                }
            } header: {
                Text(L("report.items"))
            }

            Section(L("report.content")) {
                LimitedTextField(L("report.title.placeholder"), text: $draft.title, limit: TextLimits.reportTitle)
                LimitedTextField(L("report.summary.placeholder"), text: $draft.summary, limit: TextLimits.reportSummary, axis: .vertical, lines: 2...8)
                Toggle(L("report.includeExecutor"), isOn: $draft.includeExecutor)
                if draft.includeExecutor && executorEmpty {
                    Text(L("report.executorEmpty")).font(.footnote).foregroundStyle(Color.secondary)
                }
                Toggle(L("report.includeClient"), isOn: $draft.includeClient).disabled(project.clientName.isEmpty)
                Toggle(L("report.includeWorkDate"), isOn: $draft.includeWorkDate).disabled(project.workDate == nil)
            }

            Section {
                Toggle(L("report.includeProjectAddress"), isOn: $draft.includeProjectAddress).disabled(project.siteAddress.isEmpty)
                Toggle(L("report.includePhotoLocations"), isOn: $draft.includePhotoLocations)
                Toggle(L("report.includeCoordinates"), isOn: $draft.includeCoordinates)
                PrivacyPreview(settings: draft, project: project, photos: selectedPhotos(photos: photos, pairs: completePairs))
            } header: {
                Text(L("report.privacy"))
            } footer: {
                Text(L("report.privacy.footer"))
            }

            Section(L("report.format")) {
                Picker(L("report.language"), selection: $draft.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                Picker(L("report.pageSize"), selection: $draft.pageSize) {
                    Text(L("report.pageSize.a4")).tag(PageSize.a4)
                    Text(L("report.pageSize.letter")).tag(PageSize.letter)
                }
                Picker(L("report.timeFormat"), selection: $draft.timeFormat) {
                    Text(L("format.time.system")).tag(TimeFormatOption.system)
                    Text(L("format.time.h12")).tag(TimeFormatOption.h12)
                    Text(L("format.time.h24")).tag(TimeFormatOption.h24)
                }
                Picker(L("report.dateStyle"), selection: $draft.dateStyle) {
                    Text(L("stamp.dateStyle.long")).tag(DateStyleOption.long)
                    Text(L("stamp.dateStyle.iso")).tag(DateStyleOption.iso)
                }
                Picker(L("report.quality"), selection: $draft.quality) {
                    Text(L("report.quality.standard")).tag(ReportQuality.standard)
                    Text(L("report.quality.compact")).tag(ReportQuality.compact)
                }
            }

            Section {
                if policy.canUseBranding {
                    Toggle(L("report.includeLogo"), isOn: $draft.includeLogo)
                    BrandPresetPicker(selection: $draft.brandPresetID)
                } else {
                    Button { paywallTrigger = .branding } label: {
                        Label(L("report.branding.pro"), systemImage: "star")
                    }
                    Text(L("report.branding.freeFooter")).font(.footnote).foregroundStyle(Color.secondary)
                }
            } header: {
                Text(L("report.branding"))
            }
        }
        .navigationTitle(L("report.settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { saveDefaults(); dismiss() } }
        }
        .safeAreaInset(edge: .bottom) {
            Button { generate(policy: policy) } label: {
                Text(generateTitle(policy: policy))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectionCount == 0)
            .accessibilityIdentifier("report.generate")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showItems) {
            ReportItemsPicker(project: project, template: draft.template,
                              selectedPhotos: $draft.selectedPhotoIDs, selectedPairs: $draft.selectedPairIDs)
        }
        .sheet(item: $paywallTrigger) { PaywallView(trigger: $0) }
        .errorAlert($error)
        .onAppear { load(photos: photos, pairs: completePairs) }
        .onChange(of: draft) { _, value in settings = value }
    }

    private var executorEmpty: Bool {
        guard let prefs = env.repository?.preferences() else { return true }
        return prefs.executorName.isEmpty && prefs.executorContact.isEmpty
    }

    private var selectionCount: Int {
        draft.template == .standard ? draft.selectedPhotoIDs.count : draft.selectedPairIDs.count
    }

    private func itemsSummary(photos: [PhotoRecord], completePairs: [PhotoPair], allPairs: [PhotoPair]) -> String {
        if draft.template == .standard {
            return L("report.items.selectedOf", draft.selectedPhotoIDs.count, photos.count)
        }
        return L("report.items.selectedOf", draft.selectedPairIDs.count, completePairs.count)
    }

    private func limitMessage(policy: AccessPolicy) -> String? {
        if draft.template == .standard, draft.selectedPhotoIDs.count > policy.reportPhotoLimit {
            return L("report.limit.photos", policy.reportPhotoLimit)
        }
        if draft.template == .beforeAfter, policy.isPro, draft.selectedPairIDs.count > AccessPolicy.proReportPairLimit {
            return L("report.limit.pairs", AccessPolicy.proReportPairLimit)
        }
        return nil
    }

    private func generateTitle(policy: AccessPolicy) -> String {
        if draft.template == .beforeAfter && !policy.isPro { return L("report.previewPro") }
        return L("report.create")
    }

    private func selectedPhotos(photos: [PhotoRecord], pairs: [PhotoPair]) -> [PhotoRecord] {
        if draft.template == .standard {
            let ids = Set(draft.selectedPhotoIDs)
            return photos.filter { ids.contains($0.id) }
        }
        let ids = Set(pairs.filter { draft.selectedPairIDs.contains($0.id) }.flatMap { [$0.beforePhotoID, $0.afterPhotoID].compactMap { $0 } })
        return photos.filter { ids.contains($0.id) }
    }

    private func load(photos: [PhotoRecord], pairs: [PhotoPair]) {
        guard !loaded else { return }
        loaded = true
        if let settings {
            draft = settings
            return
        }
        let defaults = project.reportDefaults
        var value = ReportSettings()
        value.template = defaults.template
        value.language = defaults.language
        value.pageSize = defaults.pageSize
        value.quality = defaults.quality
        value.timeFormat = defaults.timeFormat
        value.dateStyle = defaults.dateStyle
        value.title = project.displayTitle
        let photoIDs = photos.map(\.id)
        value.selectedPhotoIDs = preselected.isEmpty ? photoIDs : photoIDs.filter { preselected.contains($0) }
        value.selectedPairIDs = pairs.map(\.id)
        if !preselected.isEmpty { value.template = .standard }
        draft = value
        settings = value
    }

    private func saveDefaults() {
        guard let repository = env.repository else { return }
        repository.saveReportDefaults(ReportDefaults(template: draft.template, language: draft.language, pageSize: draft.pageSize,
                                                     quality: draft.quality, timeFormat: draft.timeFormat,
                                                     dateStyle: draft.dateStyle), for: project)
    }

    private func generate(policy: AccessPolicy) {
        guard let repository = env.repository else { return }
        if limitMessage(policy: policy) != nil {
            if !policy.isPro && draft.template == .standard {
                paywallTrigger = .reportLimit
            } else {
                let limit = draft.template == .standard ? policy.reportPhotoLimit : AccessPolicy.proReportPairLimit
                error = AppError(.reportLimitExceeded, arguments: [String(limit)])
            }
            return
        }
        saveDefaults()
        do {
            let snapshot = try ReportSnapshotFactory.make(project: project, settings: draft, repository: repository, isPro: policy.isPro)
            onGenerate(ReportGenerationJob(snapshot: snapshot, repository: repository, analytics: env.analytics))
        } catch {
            self.error = AppError.wrap(error, default: .reportGenerationFailed)
        }
    }
}

/// Shows exactly which place information will be published (PDF-03).
struct PrivacyPreview: View {
    let settings: ReportSettings
    let project: Project
    let photos: [PhotoRecord]

    var body: some View {
        let addresses = photos.filter { $0.location?.displayAddress != nil }.count
        let coordinates = photos.filter { $0.location?.hasCoordinates == true }.count
        VStack(alignment: .leading, spacing: 4) {
            Text(L("report.privacy.preview")).font(.footnote.weight(.semibold))
            if !settings.includeProjectAddress && !settings.includePhotoLocations && !settings.includeCoordinates {
                Text(L("report.privacy.none")).font(.footnote).foregroundStyle(Color.secondary)
            }
            if settings.includeProjectAddress && !project.siteAddress.isEmpty {
                Text(L("report.privacy.projectAddress", project.siteAddress)).font(.footnote)
            }
            if settings.includePhotoLocations {
                Text(L("report.privacy.photoLocations", addresses, photos.count)).font(.footnote)
            }
            if settings.includeCoordinates {
                Text(L("report.privacy.coordinates", coordinates, photos.count)).font(.footnote)
            }
            if settings.includeCoordinates && !settings.includePhotoLocations {
                Text(L("report.privacy.independent")).font(.footnote).foregroundStyle(Color.secondary)
            }
            if photos.contains(where: \.isImported) {
                Text(L("report.privacy.pixels")).font(.footnote).foregroundStyle(Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Selection and order of report items.
struct ReportItemsPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let template: ReportTemplate
    @Binding var selectedPhotos: [UUID]
    @Binding var selectedPairs: [UUID]

    var body: some View {
        let photos = env.repository?.photos(projectID: project.id).filter { $0.saveState == .saved } ?? []
        let pairs = (env.repository?.pairs(projectID: project.id) ?? []).filter(\.isComplete)
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button(L("common.selectAll")) {
                            if template == .standard { selectedPhotos = photos.map(\.id) } else { selectedPairs = pairs.map(\.id) }
                        }
                        Spacer()
                        Button(L("common.selectNone")) {
                            if template == .standard { selectedPhotos = [] } else { selectedPairs = [] }
                        }
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text(L("report.items.orderFooter"))
                }
                if template == .standard {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        let selected = selectedPhotos.contains(photo.id)
                        Button {
                            if selected { selectedPhotos.removeAll { $0 == photo.id } } else { selectedPhotos.append(photo.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                ThumbnailView(photoID: photo.id, originalPath: photo.originalPath)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(L("a11y.photo.number", index + 1)).foregroundStyle(Color.primary)
                                    Text(photo.caption.isEmpty ? PhotoDateText.short(photo) : photo.caption)
                                        .font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
                                }
                            }
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                } else {
                    if pairs.isEmpty {
                        Text(L("report.pairs.none")).foregroundStyle(Color.secondary)
                    }
                    ForEach(pairs) { pair in
                        let selected = selectedPairs.contains(pair.id)
                        Button {
                            if selected { selectedPairs.removeAll { $0 == pair.id } } else { selectedPairs.append(pair.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                Text(pair.title.isEmpty ? L("pair.untitled") : pair.title).foregroundStyle(Color.primary)
                            }
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .navigationTitle(L("report.items"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("common.done")) { dismiss() } } }
        }
        .onDisappear {
            // Keep the confirmed (project) order.
            let photoOrder = photos.map(\.id)
            selectedPhotos = photoOrder.filter { selectedPhotos.contains($0) }
            let pairOrder = pairs.map(\.id)
            selectedPairs = pairOrder.filter { selectedPairs.contains($0) }
        }
    }
}

struct BrandPresetPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: UUID?
    @Query(sort: \BrandPreset.createdAt) private var presets: [BrandPreset]

    var body: some View {
        Picker(L("report.brandPreset"), selection: $selection) {
            Text(L("report.brandPreset.profile")).tag(UUID?.none)
            ForEach(presets) { preset in
                Text(preset.title.isEmpty ? L("brand.untitled") : preset.title).tag(UUID?.some(preset.id))
            }
        }
    }
}
