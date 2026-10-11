import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI

/// S02 Camera. Opens fast; the project is chosen right above the shutter. Import and projects keep
/// working when the camera is denied or unavailable. No paywall over the shutter.
struct CameraScreen: View {
    let isActive: Bool

    @Environment(AppEnvironment.self) private var env
    @State private var model = CameraViewModel()
    @State private var showStampSettings = false
    @State private var showLocation = false
    @State private var showTargetPicker = false
    @State private var showImportPicker = false
    @State private var showImportLimits = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importSession: ImportSession?
    @State private var fullTargetDialog = false
    @State private var readOnlyTargetDialog = false
    @State private var paywallTrigger: PaywallTrigger?
    @State private var openedPhotoID: UUID?
    @State private var manualLocation = ""
    @Query(filter: #Predicate<AppPreferences> { $0.key == "main" }) private var preferences: [AppPreferences]

    private var prefs: AppPreferences? { preferences.first }

    private var targetProjectID: UUID? {
        guard let id = prefs?.cameraProjectID, let project = env.repository?.project(id: id), !project.isArchived else { return nil }
        return id
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                previewArea
                controls
            }
        }
        .environment(\.colorScheme, .dark)
        .toast($model.toast)
        .onAppear { if isActive { start() } }
        .onChange(of: isActive) { _, active in active ? start() : stop() }
        .onDisappear { stop() }
        .sheet(isPresented: $showStampSettings) { DefaultStampSettingsView() }
        .sheet(isPresented: $showLocation) { LocationSettingsSheet(manualLocation: $manualLocation) }
        .sheet(isPresented: $showTargetPicker) { CameraTargetPicker() }
        .sheet(item: $importSession) { session in ImportProgressView(session: session) }
        .sheet(item: $paywallTrigger) { trigger in PaywallView(trigger: trigger) }
        .sheet(item: Binding(get: { openedPhotoID.map(IdentifiedUUID.init) }, set: { openedPhotoID = $0?.id })) { item in
            NavigationStack { PhotoDetailView(photoID: item.id) }
        }
        .photosPicker(isPresented: $showImportPicker, selection: $pickerItems,
                      maxSelectionCount: importLimit, selectionBehavior: .ordered, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: pickerItems) { _, items in startImport(items) }
        .modifier(ImportLimitsDialog(isPresented: $showImportLimits,
                                     remaining: env.policy().shownRemainingPhotoSlots(for: targetProjectID)) {
            showImportPicker = true
        })
        .confirmationDialog(L("camera.full.title"), isPresented: $fullTargetDialog, titleVisibility: .visible) {
            Button(L("camera.full.saveUnsorted")) { shoot(to: nil) }
            Button(L("paywall.seePro")) { paywallTrigger = .photoLimit }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("camera.full.message", AccessPolicy.freePhotoLimit))
        }
        .confirmationDialog(L("camera.readOnly.title"), isPresented: $readOnlyTargetDialog, titleVisibility: .visible) {
            Button(L("camera.full.saveUnsorted")) { shoot(to: nil) }
            Button(L("camera.chooseProject")) { showTargetPicker = true }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("camera.readOnly.message"))
        }
    }

    // MARK: Lifecycle

    private func start() {
        model.activate()
        env.location.setCameraActive(true)
        if model.lastPhotoID == nil, let repository = env.repository {
            model.setLastPhoto(repository.photos(projectID: targetProjectID).last?.id)
        }
    }

    private func stop() {
        model.deactivate()
        env.location.setCameraActive(false)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            if model.status == .running && model.capabilities.hasFlash {
                Button { model.cycleFlash() } label: {
                    Image(systemName: flashSymbol).font(.title3).frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .accessibilityLabel(L("camera.flash"))
                .accessibilityValue(flashValue)
            }
            Spacer(minLength: 0)
            LocationChip(manualLocation: manualLocation) { showLocation = true }
            Spacer(minLength: 0)
            Button { showStampSettings = true } label: {
                Image(systemName: "textformat.size").font(.title3).frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityLabel(L("camera.stampSettings"))
            if model.status == .running && model.capabilities.canSwitchCamera {
                Button { Task { await model.switchCamera() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3)
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .disabled(model.isCapturing)
                .accessibilityLabel(L("camera.switch"))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(minHeight: 48)
    }

    private var flashSymbol: String {
        switch model.flashMode {
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        default: return "bolt.badge.automatic.fill"
        }
    }

    private var flashValue: String {
        switch model.flashMode {
        case .on: return L("camera.flash.on")
        case .off: return L("camera.flash.off")
        default: return L("camera.flash.auto")
        }
    }

    // MARK: Preview

    private var previewArea: some View {
        GeometryReader { proxy in
            let size = previewSize(in: proxy.size)
            ZStack {
                switch model.status {
                case .running, .configuring, .interrupted:
                    CameraPreviewView(session: model.service.session,
                                      onLayer: { model.attach(previewLayer: $0) },
                                      onTap: { device, layer in model.focus(devicePoint: device, layerPoint: layer) })
                    if model.status == .running {
                        StampPreviewOverlay(size: size, previewAngle: model.previewAngle, captureAngle: model.captureAngle,
                                            projectTitle: env.repository?.project(id: targetProjectID)?.displayTitle,
                                            manualLocation: manualLocation)
                            .allowsHitTesting(false)
                    }
                    if let point = model.focusIndicator {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.yellow, lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                            .position(point)
                            .allowsHitTesting(false)
                    }
                    if model.status == .interrupted {
                        CameraMessageView(icon: "pause.circle", title: L("camera.interrupted.title"),
                                          message: L("camera.interrupted.message")) {
                            Button(L("common.retry")) { model.activate() }.buttonStyle(.borderedProminent)
                        }
                        .background(Color.black.opacity(0.7))
                    }
                default:
                    CameraPermissionView(status: model.status,
                                         onRequest: { Task { await model.requestPermission() } },
                                         onImport: beginImport)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    /// 3:4 frame: the preview shows exactly the photo area, so the stamp preview matches the file.
    private func previewSize(in container: CGSize) -> CGSize {
        let width = min(container.width, container.height * 3 / 4)
        return CGSize(width: width, height: width * 4 / 3)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if model.status == .running, !model.capabilities.zoomOptions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(model.capabilities.zoomOptions) { option in
                        let selected = model.zoomFactor == option.deviceFactor
                        Button { model.setZoom(option) } label: {
                            Text(option.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(selected ? Color.yellow : .white)
                                .frame(minWidth: Theme.minTapSize, minHeight: 36)
                                .background(Circle().fill(Color.white.opacity(0.15)))
                        }
                        .accessibilityLabel(L("camera.zoom", option.label))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            targetChip
            HStack {
                lastPhotoButton.frame(maxWidth: .infinity)
                shutterButton
                Button(action: beginImport) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                }
                .accessibilityLabel(L("camera.import"))
                .accessibilityIdentifier("camera.import")
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private var targetChip: some View {
        let policy = env.policy()
        let title: String
        var detail: String?
        var warning = false
        if let id = targetProjectID, let project = env.repository?.project(id: id) {
            title = project.displayTitle
            switch policy.access(for: id) {
            case .editable:
                if !policy.isPro {
                    detail = L("camera.freeLeft", policy.remainingFreePhotos)
                    warning = policy.remainingPhotoSlots(for: id) == 0
                }
            default:
                detail = L("project.readOnly.short")
                warning = true
            }
        } else {
            title = L("projects.unsorted")
            if !policy.isPro {
                detail = L("camera.freeLeft", policy.remainingFreePhotos)
                warning = policy.isFreePhotoQuotaUsedUp
            }
        }
        return Button { showTargetPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: targetProjectID == nil ? "tray" : "folder")
                Text(title).lineLimit(1)
                if let detail {
                    Text("· " + detail).foregroundStyle(warning ? Theme.warning : .white.opacity(0.75))
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.minTapSize)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .accessibilityLabel(L("camera.target.a11y", title))
        .accessibilityHint(L("camera.target.hint"))
        .padding(.horizontal, 16)
    }

    private var shutterButton: some View {
        Button { attemptCapture() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(model.isCapturing ? Color.white.opacity(0.5) : Color.white).frame(width: 60, height: 60)
                if model.isCapturing { ProgressView().tint(.black) }
            }
        }
        .disabled(model.status != .running || model.isCapturing)
        .opacity(model.status == .running ? 1 : 0.4)
        .accessibilityLabel(L("camera.shutter"))
        .accessibilityValue(model.isCapturing ? L("camera.saving") : "")
        .sensoryFeedback(.impact(weight: .medium), trigger: model.lastPhotoID)
    }

    @ViewBuilder private var lastPhotoButton: some View {
        if let id = model.lastPhotoID, let photo = env.repository?.photo(id: id) {
            Button { openedPhotoID = id } label: {
                ThumbnailView(photoID: id, originalPath: photo.originalPath)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.8), lineWidth: 1))
            }
            .accessibilityLabel(L("camera.lastPhoto"))
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }

    // MARK: Actions

    private func attemptCapture() {
        let policy = env.policy()
        // Free photos used up: the shutter opens the paywall instead of taking a shot.
        if policy.isFreePhotoQuotaUsedUp {
            paywallTrigger = .freePhotos
            return
        }
        if let id = targetProjectID {
            switch policy.access(for: id) {
            case .editable:
                if policy.remainingPhotoSlots(for: id) <= 0 {
                    // Explicit attempt to add beyond the limit — offer options instead of an ad.
                    if policy.isPro { model.toast = ToastMessage(text: L("camera.full.pro", AccessPolicy.proPhotoLimit), kind: .error) }
                    else { fullTargetDialog = true }
                    return
                }
                shoot(to: id)
            default:
                readOnlyTargetDialog = true
            }
        } else {
            shoot(to: nil)
        }
    }

    private func shoot(to projectID: UUID?) {
        let label = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await model.capture(projectID: projectID, env: env, manualLocation: label.isEmpty ? nil : label) }
    }

    private var importLimit: Int {
        max(1, min(AccessPolicy.importBatchLimit, env.policy().remainingPhotoSlots(for: targetProjectID)))
    }

    private func beginImport() {
        let policy = env.policy()
        if policy.isFreePhotoQuotaUsedUp {
            paywallTrigger = .freePhotos
            return
        }
        if let id = targetProjectID {
            guard policy.access(for: id) == .editable else { readOnlyTargetDialog = true; return }
            if policy.remainingPhotoSlots(for: id) <= 0 {
                if policy.isPro { model.toast = ToastMessage(text: L("camera.full.pro", AccessPolicy.proPhotoLimit), kind: .error) }
                else { paywallTrigger = .photoLimit }
                return
            }
        }
        pickerItems = []
        let remaining = policy.shownRemainingPhotoSlots(for: targetProjectID)
        if ImportLimitsDialog.shouldShow(remaining: remaining) { showImportLimits = true } else { showImportPicker = true }
    }

    private func startImport(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, let repository = env.repository else { return }
        let projectID = targetProjectID
        let session = ImportSession(projectID: projectID, pickerItems: items, repository: repository, files: env.files,
                                    analytics: env.analytics) { [env] in
            env.policy().remainingPhotoSlots(for: projectID)
        }
        importSession = session
        session.start()
        pickerItems = []
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// Message shown in the preview area (denied, unavailable, interrupted).
struct CameraMessageView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            actions()
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// S03 camera access: explanation first, one system prompt, then Settings + Import after a refusal.
struct CameraPermissionView: View {
    let status: CameraViewModel.Status
    let onRequest: () -> Void
    let onImport: () -> Void

    var body: some View {
        ScrollView {
            switch status {
            case .needsPermission, .requesting:
                CameraMessageView(icon: "camera", title: L("camera.permission.title"), message: L("camera.permission.message")) {
                    Button(L("camera.permission.allow"), action: onRequest)
                        .buttonStyle(.borderedProminent)
                        .disabled(status == .requesting)
                    Button(L("camera.import"), action: onImport).buttonStyle(.bordered)
                }
            case .denied:
                CameraMessageView(icon: "camera.badge.ellipsis", title: L("camera.denied.title"), message: L("camera.denied.message")) {
                    Button(L("common.openSettings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L("camera.import"), action: onImport).buttonStyle(.bordered)
                }
            case .restricted:
                CameraMessageView(icon: "lock", title: L("camera.restricted.title"), message: L("camera.restricted.message")) {
                    Button(L("camera.import"), action: onImport).buttonStyle(.borderedProminent)
                }
            case .unavailable:
                CameraMessageView(icon: "camera.metering.unknown", title: L("camera.unavailable.title"), message: L("camera.unavailable.message")) {
                    Button(L("camera.import"), action: onImport).buttonStyle(.borderedProminent)
                }
            case .failed(let code):
                CameraMessageView(icon: "exclamationmark.triangle", title: L("camera.failed.title"),
                                  message: AppError(code).displayMessage) {
                    Button(L("camera.import"), action: onImport).buttonStyle(.bordered)
                }
            default:
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Short geostatus on the camera; details open on tap (no long warnings over the frame).
struct LocationChip: View {
    @Environment(AppEnvironment.self) private var env
    let manualLocation: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(text).lineLimit(1)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .frame(minHeight: Theme.minTapSize)
        }
        .accessibilityLabel(L("camera.location.a11y", text))
    }

    private var symbol: String {
        switch env.location.phase {
        case .off, .idle: return manualLocation.isEmpty ? "location.slash" : "mappin"
        case .needsPermission: return "location"
        case .denied, .restricted: return "location.slash"
        case .locating: return "location.circle"
        case .ready: return env.location.reducedAccuracy ? "location.circle" : "location.fill"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var text: String {
        let location = env.location
        switch location.phase {
        case .off, .idle:
            return manualLocation.isEmpty ? L("location.status.off") : L("location.status.manual")
        case .needsPermission: return L("location.status.needsPermission")
        case .denied: return L("location.status.denied")
        case .restricted: return L("location.status.restricted")
        case .locating: return L("location.status.locating")
        case .unavailable: return L("location.status.unavailable")
        case .ready:
            guard let latest = location.latest else { return L("location.status.locating") }
            let accuracy = DistanceFormatting.string(meters: latest.horizontalAccuracy, locale: AppLanguage.current.formattingLocale)
            if location.reducedAccuracy || latest.horizontalAccuracy > LocationPolicy.preciseAccuracyLimit {
                return L("location.status.approximate", accuracy)
            }
            return "±" + accuracy
        }
    }
}

/// Live stamp preview drawn with the same renderer as the final file.
struct StampPreviewOverlay: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var displayScale
    let size: CGSize
    let previewAngle: CGFloat
    let captureAngle: CGFloat
    let projectTitle: String?
    let manualLocation: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            overlay(now: context.date)
        }
    }

    @ViewBuilder
    private func overlay(now: Date) -> some View {
        // The photo is rotated by (capture − preview) relative to what is on screen.
        let delta = (previewAngle - captureAngle).truncatingRemainder(dividingBy: 360)
        let quarterTurn = abs(delta.truncatingRemainder(dividingBy: 180)) == 90
        let canvas = quarterTurn ? CGSize(width: size.height, height: size.width) : size
        if let repository = env.repository {
            let settings = repository.preferences().defaultStamp
            let offset = TimeZone.current.secondsFromGMT(for: now)
            let input = StampInput(dateInfo: PhotoDateInfo(kind: .device, local: LocalDateTime(date: now, offsetSeconds: offset),
                                                           offsetSeconds: offset),
                                   isImported: false, projectTitle: projectTitle, location: previewLocation,
                                   shortCaption: settings.fields.caption ? L("camera.stampPreview.caption") : "")
            let lines = StampContentBuilder.lines(input: input, settings: settings, language: .current, includeLocation: true)
            if let layout = StampRenderer.layout(lines: lines, settings: settings, imageSize: canvas),
               let image = StampRenderer.overlayImage(layout, scale: displayScale) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: layout.boxRect.width, height: layout.boxRect.height)
                        .offset(x: layout.boxRect.minX, y: layout.boxRect.minY)
                }
                .frame(width: canvas.width, height: canvas.height)
                .rotationEffect(.degrees(delta))
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var previewLocation: PhotoLocation? {
        var location = PhotoLocation(source: .device)
        if let latest = env.location.latest, env.location.isEnabled, env.location.phase == .ready {
            location.latitude = latest.coordinate.latitude
            location.longitude = latest.coordinate.longitude
            location.horizontalAccuracy = latest.horizontalAccuracy
            location.accuracyAuthorization = env.location.reducedAccuracy ? .reduced : .full
        }
        let manual = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            location.addressOverride = manual
            location.addressOverrideKind = .manual
        } else if location.hasCoordinates {
            location.addressOriginal = L("camera.stampPreview.addressAfterCapture")
        }
        return location.isEmpty ? nil : location
    }
}
