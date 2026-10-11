import SwiftUI

/// Pairs tab of a project.
struct PairsListSection: View {
    let project: Project
    let pairs: [PhotoPair]
    let photos: [PhotoRecord]
    let canEdit: Bool
    let onOpen: (PairRequest) -> Void

    var body: some View {
        let complete = pairs.filter(\.isComplete).count
        VStack(alignment: .leading, spacing: 10) {
            Text(L("pairs.summary", complete, pairs.count - complete))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            if pairs.isEmpty {
                ContentUnavailableView(L("pairs.empty.title"), systemImage: "rectangle.split.2x1",
                                       description: Text(L("pairs.empty.message")))
            }
            ForEach(pairs) { pair in
                Button {
                    onOpen(PairRequest(pairID: pair.id, before: pair.beforePhotoID, after: pair.afterPhotoID))
                } label: {
                    PairRow(pair: pair, photos: photos)
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
            }
            if canEdit {
                Button {
                    onOpen(PairRequest(pairID: nil, before: nil, after: nil))
                } label: {
                    Label(L("pairs.new"), systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
                }
                .buttonStyle(.bordered)
                .disabled(photos.count < 2)
            }
        }
    }
}

struct PairRow: View {
    let pair: PhotoPair
    let photos: [PhotoRecord]

    var body: some View {
        HStack(spacing: 10) {
            slot(pair.beforePhotoID, label: L("pair.role.beforeShort"))
            slot(pair.afterPhotoID, label: L("pair.role.afterShort"))
            VStack(alignment: .leading, spacing: 3) {
                Text(pair.title.isEmpty ? L("pair.untitled") : pair.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Label(pair.isComplete ? L("pair.state.complete") : L("pair.state.draft"),
                      systemImage: pair.isComplete ? "checkmark.circle" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(pair.isComplete ? Theme.success : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func slot(_ id: UUID?, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            if let id, let photo = photos.first(where: { $0.id == id }) {
                ThumbnailView(photoID: id, originalPath: photo.originalPath)
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "plus").foregroundStyle(Color.secondary)
                }
            }
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(3)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(3)
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// S10 pair editor: choose two photos of the same project, order, title, note, preview.
struct PairEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let pairID: UUID?
    @State var before: UUID?
    @State var after: UUID?
    @State private var title = ""
    @State private var caption = ""
    @State private var choosing: Side?
    @State private var error: AppError?
    @State private var confirmDelete = false
    @State private var loaded = false
    @State private var openedPhoto: IdentifiedUUID?

    enum Side: String, Identifiable {
        case before
        case after
        var id: String { rawValue }
    }

    init(project: Project, pairID: UUID?, before: UUID?, after: UUID?) {
        self.project = project
        self.pairID = pairID
        _before = State(initialValue: before)
        _after = State(initialValue: after)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        slot(.before)
                        slot(.after)
                    }
                    Button { swap(&before, &after) } label: {
                        Label(L("pair.swap"), systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(before == nil && after == nil)
                } footer: {
                    Text(L("pair.footer"))
                }
                Section(L("pair.details")) {
                    LimitedTextField(L("pair.title.placeholder"), text: $title, limit: TextLimits.pairTitle)
                    LimitedTextField(L("pair.caption.placeholder"), text: $caption, limit: TextLimits.pairCaption, axis: .vertical, lines: 2...6)
                }
                if before == nil || after == nil {
                    Section {
                        Label(L("pair.draft.hint"), systemImage: "info.circle").font(.footnote)
                    }
                }
                if pairID != nil {
                    Section {
                        Button(L("pair.delete"), role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(pairID == nil ? L("pairs.new") : L("pair.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                        .disabled(before == nil && after == nil)
                }
            }
            .sheet(item: $choosing) { side in
                PairPhotoChooser(project: project, pairID: pairID, excluded: side == .before ? after : before,
                                 selected: side == .before ? before : after) { id in
                    if side == .before { before = id } else { after = id }
                }
            }
            .confirmationDialog(L("pair.delete"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("pair.delete"), role: .destructive) {
                    if let pair = env.repository?.pair(id: pairID) { try? env.repository?.deletePair(pair) }
                    dismiss()
                }
            } message: {
                Text(L("pair.delete.message"))
            }
            .errorAlert($error)
            .sheet(item: $openedPhoto) { item in
                NavigationStack { PhotoDetailView(photoID: item.id) }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let pair = env.repository?.pair(id: pairID) {
                title = pair.title
                caption = pair.caption
            }
        }
    }

    @ViewBuilder
    private func slot(_ side: Side) -> some View {
        let id = side == .before ? before : after
        let photo = env.repository?.photo(id: id)
        Button { choosing = side } label: {
            VStack(spacing: 6) {
                Text(side == .before ? L("pair.role.before") : L("pair.role.after"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                ZStack {
                    if let photo {
                        ThumbnailView(photoID: photo.id, originalPath: photo.originalPath, contentMode: .fit)
                    } else {
                        Color(.tertiarySystemFill)
                        VStack(spacing: 4) {
                            Image(systemName: "plus.circle").font(.title2)
                            Text(L("pair.choose")).font(.caption)
                        }
                        .foregroundStyle(Color.secondary)
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(side == .before ? L("pair.role.before") : L("pair.role.after"))
        .accessibilityValue(photo == nil ? L("pair.empty.a11y") : L("pair.chosen.a11y"))
        .overlay(alignment: .bottom) {
            if let photo {
                Button { openedPhoto = IdentifiedUUID(id: photo.id) } label: {
                    Label(L("pair.openPhoto"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 32)
                        .background(Capsule().fill(.regularMaterial))
                }
                .padding(6)
            }
        }
    }

    private func save() {
        guard let repository = env.repository else { return }
        do {
            if let pair = repository.pair(id: pairID) {
                try repository.updatePair(pair, before: before, after: after, title: title, caption: caption)
            } else {
                try repository.createPair(projectID: project.id, before: before, after: after, title: title, caption: caption)
            }
            if before != nil && after != nil { env.analytics.track(.pairCompleted) }
            dismiss()
        } catch {
            self.error = AppError.wrap(error, default: .pairInvalid)
        }
    }
}

/// Photos of the same project that are not in another pair.
struct PairPhotoChooser: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let pairID: UUID?
    let excluded: UUID?
    let selected: UUID?
    let onChoose: (UUID?) -> Void

    var body: some View {
        let repository = env.repository
        let candidates = (repository?.photos(projectID: project.id) ?? []).filter { photo in
            guard photo.id != excluded, photo.saveState == .saved else { return false }
            if let other = repository?.pair(containing: photo.id), other.id != pairID { return false }
            return true
        }
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    ContentUnavailableView(L("pair.chooser.empty"), systemImage: "photo")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                    ForEach(candidates) { photo in
                        Button {
                            onChoose(photo.id)
                            dismiss()
                        } label: {
                            PhotoCell(photo: photo, isSelected: photo.id == selected, isSelecting: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                Text(L("pair.chooser.footer")).font(.footnote).foregroundStyle(Color.secondary).padding()
            }
            .navigationTitle(L("pair.choose"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                if selected != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(L("pair.clearSlot")) {
                            onChoose(nil)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
