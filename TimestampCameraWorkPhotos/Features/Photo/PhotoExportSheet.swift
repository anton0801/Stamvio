import SwiftUI

/// STAMP-03 export of one or several photos.
/// - Stamped JPEG: one at a time in Free (≤ 2560 px); several (ZIP) and original resolution in Pro.
/// - Original files: always free.
/// - "Without location" removes GPS from EXIF and address/coordinates from the stamp.
struct PhotoExportSheet: View {
    enum Kind: Hashable {
        case stamped
        case original
    }

    enum Resolution: Hashable {
        case limited
        case original
    }

    let request: PhotoExportRequest
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .stamped
    @State private var includeLocation = false
    @State private var resolution: Resolution = .limited
    @State private var isWorking = false
    @State private var progress: (Int, Int) = (0, 0)
    @State private var shareRequest: ShareRequest?
    @State private var filesRequest: ExportFilesRequest?
    @State private var paywallTrigger: PaywallTrigger?
    @State private var error: AppError?
    @State private var toast: ToastMessage?
    @State private var initialized = false
    @State private var previewImage: CGImage?

    private var photos: [PhotoRecord] { env.repository?.photos(ids: request.photoIDs).filter { $0.saveState == .saved } ?? [] }

    var body: some View {
        let policy = env.policy()
        let items = photos
        NavigationStack {
            Form {
                Section {
                    Picker(L("export.kind"), selection: $kind) {
                        Text(L("export.kind.stamped")).tag(Kind.stamped)
                        Text(L("export.kind.original")).tag(Kind.original)
                    }
                    .pickerStyle(.segmented)
                    if items.count > 1 && kind == .stamped && !policy.canBatchExport {
                        Label(L("export.batch.pro"), systemImage: "star").font(.footnote)
                    }
                } footer: {
                    Text(kind == .stamped ? L("export.kind.stamped.footer") : L("export.kind.original.footer"))
                }

                if kind == .stamped, items.count == 1, let photo = items.first, let previewImage {
                    Section(L("export.preview")) {
                        StampPreviewImage(settings: photo.stamp?.settings ?? .default,
                                          input: StampInput(dateInfo: photo.dateInfo, isImported: photo.isImported,
                                                            projectTitle: request.projectTitle, location: photo.location,
                                                            shortCaption: photo.stampCaption),
                                          baseImage: previewImage, includeLocation: includeLocation)
                    }
                }

                Section {
                    Toggle(L("export.includeLocation"), isOn: $includeLocation)
                    if !includeLocation {
                        Text(L("export.withoutLocation.explanation")).font(.footnote).foregroundStyle(Color.secondary)
                        if items.contains(where: { !$0.caption.isEmpty }) {
                            Label(L("export.withoutLocation.caption"), systemImage: "text.bubble").font(.footnote)
                        }
                        if items.contains(where: \.isImported) {
                            Label(L("export.withoutLocation.pixels"), systemImage: "photo").font(.footnote)
                        }
                    }
                } header: {
                    Text(L("export.privacy"))
                }

                if kind == .stamped {
                    Section(L("export.resolution")) {
                        Picker(L("export.resolution"), selection: Binding(get: { resolution }, set: { value in
                            if value == .original && !policy.isPro { paywallTrigger = .originalResolution } else { resolution = value }
                        })) {
                            Text(L("export.resolution.limited", AccessPolicy.freeExportMaxPixel)).tag(Resolution.limited)
                            Text(L("export.resolution.original") + (policy.isPro ? "" : " · Pro")).tag(Resolution.original)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                Section {
                    Button { Task { await prepare(destination: .share, items: items) } } label: {
                        Label(L("export.share"), systemImage: "square.and.arrow.up")
                    }
                    Button { Task { await prepare(destination: .files, items: items) } } label: {
                        Label(L("export.saveFiles"), systemImage: "folder")
                    }
                    if kind == .stamped || items.count <= 10 {
                        Button { Task { await prepare(destination: .photos, items: items) } } label: {
                            Label(L("export.savePhotos"), systemImage: "photo.on.rectangle")
                        }
                    }
                } footer: {
                    if isWorking {
                        HStack {
                            ProgressView()
                            Text(L("export.progress", progress.0, max(progress.1, 1)))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .disabled(isWorking || items.isEmpty)
            }
            .navigationTitle(items.count == 1 ? L("export.title.one") : L("export.title.many", items.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("common.close")) { dismiss() } } }
            .sheet(item: $shareRequest) { share in
                ShareSheet(items: share.items) { completed in
                    if completed { env.analytics.track(.shareCompleted(source: share.source)) }
                }
            }
            .sheet(item: $filesRequest) { request in
                DocumentExportPicker(urls: request.urls) { saved in
                    if saved { toast = ToastMessage(text: L("export.saved"), kind: .success) }
                }
            }
            .sheet(item: $paywallTrigger) { PaywallView(trigger: $0) }
            .errorAlert($error)
            .toast($toast)
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            // Location is included by default only when the stamp itself shows it.
            includeLocation = items.contains { $0.stamp?.settings.fields.includesLocation == true }
            if items.count == 1, let photo = items.first {
                let files = env.files
                let path = photo.originalPath
                Task {
                    previewImage = await Task.detached {
                        (try? files.url(forRelative: path)).flatMap { ImageLoader.orientedImage(url: $0, maxPixel: 1200) }
                    }.value
                }
            }
        }
    }

    private enum Destination {
        case share
        case files
        case photos
    }

    private func prepare(destination: Destination, items: [PhotoRecord]) async {
        // One export at a time: a fast double tap does not start a second one.
        guard !isWorking else { return }
        let policy = env.policy()
        if kind == .stamped && items.count > 1 && !policy.canBatchExport {
            paywallTrigger = .batchExport
            return
        }
        guard let repository = env.repository else { return }
        isWorking = true
        defer { isWorking = false }
        let defaultStamp = repository.preferences().defaultStamp
        let exportItems = items.enumerated().map { index, photo in
            PhotoExportItem(photo: photo, projectTitle: request.projectTitle, number: number(of: photo, fallback: index + 1),
                            defaultStamp: defaultStamp)
        }
        let options = ExportOptions(includeLocation: includeLocation,
                                    maxPixel: resolution == .original && policy.isPro ? nil : AccessPolicy.freeExportMaxPixel)
        let files = env.files
        let kind = self.kind
        let lease = files.lease(exportItems.map(\.originalPath))
        defer { files.endLease(lease) }
        progress = (0, exportItems.count)
        do {
            let urls: [URL] = try await Task.detached(priority: .userInitiated) {
                let directory = try files.newTempDirectory()
                switch kind {
                case .original:
                    return try exportItems.map { try ImageExporter.originalCopy($0, includeLocation: options.includeLocation, files: files, directory: directory) }
                case .stamped:
                    if exportItems.count == 1 || destination == .photos {
                        return try exportItems.map { try ImageExporter.writeStamped($0, options: options, files: files, directory: directory) }
                    }
                    let name = (exportItems.first.map(ImageExporter.exportBaseName)?.components(separatedBy: "-").first ?? "Photos")
                        + "_stamped_\(WorkDate.isoString(from: Date())).zip"
                    return [try ImageExporter.stampedZIP(exportItems, options: options, files: files, archiveName: name,
                                                         progress: { _, _ in }, isCancelled: { false })]
                }
            }.value
            progress = (exportItems.count, exportItems.count)
            switch destination {
            case .share:
                env.analytics.track(.shareSheetOpened(source: .photo))
                shareRequest = ShareRequest(items: urls, source: .photo)
            case .files:
                filesRequest = ExportFilesRequest(urls: urls)
            case .photos:
                for url in urls { try await ImageExporter.saveToPhotos(fileURL: url) }
                toast = ToastMessage(text: L("export.savedPhotos", urls.count), kind: .success)
            }
        } catch {
            let appError = AppError.wrap(error, default: .exportFailed)
            ErrorLog.shared.record(appError.code)
            self.error = appError
        }
    }

    private func number(of photo: PhotoRecord, fallback: Int) -> Int {
        guard let repository = env.repository else { return fallback }
        let list = repository.photos(projectID: photo.projectID)
        return (list.firstIndex(where: { $0.id == photo.id }) ?? (fallback - 1)) + 1
    }
}
