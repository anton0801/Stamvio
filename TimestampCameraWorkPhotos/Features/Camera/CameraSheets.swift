import CoreLocation
import SwiftData
import SwiftUI

/// S05 location: off by default; When-In-Use is requested only after the user turns it on.
struct LocationSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Binding var manualLocation: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L("location.toggle"), isOn: Binding(get: { env.location.isEnabled }, set: setEnabled))
                } footer: {
                    Text(L("location.toggle.footer"))
                }
                Section(L("location.status")) {
                    statusRow
                    if env.location.phase == .denied {
                        Button(L("common.openSettings")) { openSettings() }
                    }
                    if env.location.phase == .ready && env.location.reducedAccuracy {
                        Text(L("location.approximate.explanation")).font(.footnote).foregroundStyle(Color.secondary)
                        Button(L("common.openSettings")) { openSettings() }
                    }
                    if env.location.phase == .unavailable {
                        Button(L("common.retry")) { env.location.retry() }
                    }
                }
                Section {
                    TextField(L("location.manual.placeholder"), text: $manualLocation, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: manualLocation) { _, value in
                            if value.count > TextLimits.manualAddress { manualLocation = String(value.prefix(TextLimits.manualAddress)) }
                        }
                    if !manualLocation.isEmpty {
                        Button(L("location.manual.clear"), role: .destructive) { manualLocation = "" }
                    }
                } header: {
                    Text(L("location.manual.header"))
                } footer: {
                    Text(L("location.manual.footer"))
                }
                Section {
                    Text(L("location.privacy")).font(.footnote).foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle(L("location.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("common.done")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func setEnabled(_ enabled: Bool) {
        env.location.isEnabled = enabled
        if enabled { env.location.requestPermissionIfNeeded() }
        if let repository = env.repository {
            repository.preferences().locationEnabled = enabled
            try? repository.save()
        }
    }

    @ViewBuilder private var statusRow: some View {
        let location = env.location
        switch location.phase {
        case .off:
            Label(L("location.status.offLong"), systemImage: "location.slash")
        case .idle:
            Label(L("location.status.idle"), systemImage: "location")
        case .needsPermission:
            Label(L("location.status.needsPermission"), systemImage: "location")
        case .denied:
            Label(L("location.status.deniedLong"), systemImage: "location.slash").foregroundStyle(Theme.destructive)
        case .restricted:
            Label(L("location.status.restricted"), systemImage: "lock")
        case .locating:
            HStack { ProgressView(); Text(L("location.status.locating")) }
        case .unavailable:
            Label(L("location.status.unavailableLong"), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        case .ready:
            if let latest = location.latest {
                let accuracy = DistanceFormatting.string(meters: latest.horizontalAccuracy, locale: AppLanguage.current.formattingLocale)
                if location.reducedAccuracy || latest.horizontalAccuracy > LocationPolicy.preciseAccuracyLimit {
                    Label(L("location.status.approximate", accuracy), systemImage: "location.circle")
                } else {
                    Label(L("location.status.precise", accuracy), systemImage: "location.fill")
                }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Camera target: Unsorted or an editable project. Read-only projects are shown with the reason.
struct CameraTargetPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(filter: #Predicate<AppPreferences> { $0.key == "main" }) private var preferences: [AppPreferences]
    @State private var showCreate = false

    var body: some View {
        let policy = env.policy()
        NavigationStack {
            List {
                Section {
                    row(title: L("projects.unsorted"), subtitle: L("projects.unsorted.subtitle"), icon: "tray",
                        selected: preferences.first?.cameraProjectID == nil, enabled: true) { select(nil) }
                }
                Section(L("projects.active")) {
                    ForEach(projects.filter { !$0.isArchived }) { project in
                        let access = policy.access(for: project.id)
                        let count = env.repository?.photoCount(projectID: project.id) ?? 0
                        row(title: project.displayTitle,
                            subtitle: access == .editable
                                ? (policy.isPro ? L("project.photoCount", count) : L("camera.target.count", count, AccessPolicy.freePhotoLimit)
                                    + " · " + L("camera.freeLeft", policy.remainingFreePhotos))
                                : L("project.readOnly.short"),
                            icon: access == .editable ? "folder" : "lock",
                            selected: preferences.first?.cameraProjectID == project.id,
                            enabled: access == .editable) { select(project.id) }
                    }
                    Button {
                        showCreate = true
                    } label: {
                        Label(L("projects.new"), systemImage: "plus")
                    }
                }
            }
            .navigationTitle(L("camera.target.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("common.done")) { dismiss() } }
            }
            .sheet(isPresented: $showCreate) {
                ProjectEditView(project: nil) { created in
                    if let created { select(created.id) }
                }
            }
        }
    }

    private func row(title: String, subtitle: String, icon: String, selected: Bool, enabled: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(enabled ? Color.accentColor : .secondary).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(Color.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(Color.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .frame(minHeight: Theme.minTapSize)
        }
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ id: UUID?) {
        guard let repository = env.repository else { return }
        repository.preferences().cameraProjectID = id
        try? repository.save()
        dismiss()
    }
}

/// Per-item import progress with partial results and retry of failed items only (IMP-01).
struct ImportProgressView: View {
    @Environment(\.dismiss) private var dismiss
    let session: ImportSession

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        if session.isRunning { ProgressView() }
                        Text(summary).font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
                Section {
                    ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 10) {
                            statusIcon(item.status)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("import.item", index + 1)).font(.subheadline)
                                Text(statusText(item.status)).font(.footnote).foregroundStyle(Color.secondary)
                                if item.status == .duplicate {
                                    Button(L("import.duplicate.importAnyway")) { session.importDuplicateAnyway(item.id) }
                                        .font(.footnote)
                                        .disabled(session.isRunning)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(L("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if session.isRunning {
                        Button(L("common.cancel")) { session.cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !session.isRunning {
                        Button(L("common.done")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if !session.isRunning && session.failedCount > 0 {
                        Button(L("import.retryFailed", session.failedCount)) { session.retryFailed() }
                    }
                }
            }
            .interactiveDismissDisabled(session.isRunning)
        }
    }

    private var summary: String {
        if session.isRunning { return L("import.progress", session.savedCount, session.items.count) }
        return L("import.done", session.savedCount, session.items.count)
    }

    @ViewBuilder private func statusIcon(_ status: ImportSession.Status) -> some View {
        switch status {
        case .waiting: Image(systemName: "clock").foregroundStyle(Color.secondary)
        case .loading: ProgressView()
        case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.destructive)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(Color.secondary)
        case .duplicate: Image(systemName: "doc.on.doc").foregroundStyle(Theme.warning)
        }
    }

    private func statusText(_ status: ImportSession.Status) -> String {
        switch status {
        case .waiting: return L("import.status.waiting")
        case .loading: return L("import.status.loading")
        case .saved: return L("import.status.saved")
        case .failed(let error): return error.displayMessage
        case .cancelled: return L("import.status.cancelled")
        case .duplicate: return L("import.status.duplicate")
        }
    }
}
