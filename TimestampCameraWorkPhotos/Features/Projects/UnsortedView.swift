import SwiftData
import SwiftUI

/// CAM-03 Unsorted: quick shots without a project. Not limited artificially in Free (only by
/// device storage). Photos can be viewed, deleted, shared as images or moved into a project.
/// No PDF from Unsorted (it is not a way around the Free project limit).
struct UnsortedView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var photos: [PhotoRecord]
    @State private var isSelecting = false
    @State private var selection: [UUID] = []
    @State private var moveRequest: [UUID]?
    @State private var exportRequest: PhotoExportRequest?
    @State private var deleteRequest: [UUID]?

    init() {
        let none: UUID? = nil
        let saved = SaveState.saved.rawValue
        let missing = SaveState.missingFile.rawValue
        _photos = Query(filter: #Predicate<PhotoRecord> {
            $0.projectID == none && ($0.saveStateRaw == saved || $0.saveStateRaw == missing)
        }, sort: [SortDescriptor(\PhotoRecord.order), SortDescriptor(\PhotoRecord.createdAt)])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("unsorted.explanation"))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .padding(.top, 8)
                if photos.isEmpty {
                    ContentUnavailableView(L("unsorted.empty.title"), systemImage: "tray",
                                           description: Text(L("unsorted.empty.message")))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            let cell = PhotoCell(photo: photo, index: index + 1, isSelected: selection.contains(photo.id),
                                                 isSelecting: isSelecting)
                            if isSelecting {
                                Button {
                                    if let i = selection.firstIndex(of: photo.id) { selection.remove(at: i) } else { selection.append(photo.id) }
                                } label: { cell }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: ProjectsRoute.photo(photo.id)) { cell }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Theme.groupedBackground)
        .navigationTitle(L("projects.unsorted"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? L("common.done") : L("common.select")) {
                    isSelecting.toggle()
                    selection = []
                }
                .disabled(photos.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack(spacing: 8) {
                    Button { moveRequest = selection } label: { Label(L("photo.move"), systemImage: "folder") }
                    Button { exportRequest = PhotoExportRequest(photoIDs: selection, projectTitle: nil) } label: {
                        Label(L("photo.export"), systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { deleteRequest = selection } label: { Label(L("common.delete"), systemImage: "trash") }
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .sheet(item: Binding(get: { moveRequest.map(IdentifiedIDs.init) }, set: { moveRequest = $0?.ids })) { request in
            MoveToProjectSheet(photoIDs: request.ids, currentProjectID: nil) {
                selection = []
                isSelecting = false
            }
        }
        .sheet(item: $exportRequest) { PhotoExportSheet(request: $0) }
        .modifier(DeletePhotosDialog(photoIDs: $deleteRequest) {
            selection = []
            isSelecting = false
        })
    }
}

/// Moves photos between projects/Unsorted, respecting the target's limit (paywall on explicit overflow).
struct MoveToProjectSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [UUID]
    let currentProjectID: UUID?
    var onMoved: () -> Void
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @State private var paywallTrigger: PaywallTrigger?
    @State private var error: AppError?
    @State private var showCreate = false

    var body: some View {
        let policy = env.policy()
        NavigationStack {
            List {
                Section {
                    Text(L("move.explanation", photoIDs.count)).font(.footnote).foregroundStyle(Color.secondary)
                }
                if currentProjectID != nil {
                    Section {
                        Button { move(to: nil) } label: {
                            Label(L("projects.unsorted"), systemImage: "tray")
                        }
                    }
                }
                Section(L("projects.active")) {
                    ForEach(projects.filter { !$0.isArchived && $0.id != currentProjectID }) { project in
                        let remaining = policy.projectCapacity(for: project.id)
                        let editable = policy.access(for: project.id) == .editable
                        Button { move(to: project.id) } label: {
                            VStack(alignment: .leading) {
                                Text(project.displayTitle).foregroundStyle(Color.primary)
                                Text(editable ? L("move.remaining", remaining) : L("project.readOnly.short"))
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(minHeight: Theme.minTapSize)
                        }
                        .disabled(!editable)
                    }
                    Button { showCreate = true } label: { Label(L("projects.new"), systemImage: "plus") }
                }
            }
            .navigationTitle(L("move.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } } }
            .sheet(item: $paywallTrigger) { PaywallView(trigger: $0) }
            .sheet(isPresented: $showCreate) { ProjectEditView(project: nil) { created in if let created { move(to: created.id) } } }
            .errorAlert($error)
        }
    }

    private func move(to projectID: UUID?) {
        guard let repository = env.repository else { return }
        let policy = env.policy()
        if let projectID {
            // Never move more than the target can take; never cut silently. Moving does not use the
            // Free quota of new photos — these photos already exist.
            if policy.projectCapacity(for: projectID) < photoIDs.count {
                if policy.isPro {
                    error = AppError(.photoLimitReached, arguments: [String(AccessPolicy.proPhotoLimit)])
                } else {
                    paywallTrigger = .photoLimit
                }
                return
            }
        }
        do {
            try repository.move(repository.photos(ids: photoIDs), to: projectID)
            env.persistFreeSelection()
            onMoved()
            dismiss()
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }
}

/// Manual order by drag and drop (saved as explicit order). VoiceOver users can use the move actions.
struct ReorderPhotosView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var order: [PhotoRecord] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, photo in
                    HStack(spacing: 12) {
                        ThumbnailView(photoID: photo.id, originalPath: photo.originalPath)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(L("a11y.photo.number", index + 1)).font(.subheadline.weight(.medium))
                            Text(photo.caption.isEmpty ? PhotoDateText.short(photo) : photo.caption)
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: L("reorder.moveUp")) { move(index, by: -1) }
                    .accessibilityAction(named: L("reorder.moveDown")) { move(index, by: 1) }
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L("sort.manual"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        try? env.repository?.setOrder(order.map(\.id), projectID: projectID)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { order = env.repository?.photos(projectID: projectID) ?? [] }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }
}

enum PhotoDateText {
    /// Short local display of the capture time with its provenance (never invents a time zone).
    @MainActor
    static func short(_ photo: PhotoRecord) -> String {
        let strings = LocalizedStrings(language: .current)
        let formatting = DateTimeFormatting(locale: AppLanguage.current.formattingLocale)
        return ProvenanceText.time(photo.dateInfo, isImported: photo.isImported, strings: strings, formatting: formatting)
    }
}
