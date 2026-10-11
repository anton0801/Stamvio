import SwiftData
import SwiftUI

struct ProjectsTab: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var router = env.router
        NavigationStack(path: $router.projectsPath) {
            ProjectsListView()
                .navigationDestination(for: ProjectsRoute.self) { route in
                    switch route {
                    case .project(let id): ProjectDetailView(projectID: id)
                    case .unsorted: UnsortedView()
                    case .photo(let id): PhotoDetailView(photoID: id)
                    case .report(let id): SavedReportView(reportID: id)
                    }
                }
        }
    }
}

/// S06 projects: active and archive, local search by title/site/client, Unsorted, empty state.
struct ProjectsListView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @State private var showArchive = false
    @State private var search = ""
    @State private var showCreate = false
    @State private var paywallTrigger: PaywallTrigger?

    private var filtered: [Project] {
        let scoped = projects.filter { $0.isArchived == showArchive }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.siteAddress.localizedCaseInsensitiveContains(query)
                || $0.clientName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let policy = env.policy()
        List {
            Section {
                Picker(L("projects.scope"), selection: $showArchive) {
                    Text(L("projects.active")).tag(false)
                    Text(L("projects.archive")).tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !showArchive && search.isEmpty {
                Section {
                    NavigationLink(value: ProjectsRoute.unsorted) {
                        UnsortedRow()
                    }
                    .accessibilityIdentifier("projects.unsorted")
                }
            }

            Section {
                if filtered.isEmpty {
                    emptyState
                } else {
                    ForEach(filtered) { project in
                        NavigationLink(value: ProjectsRoute.project(project.id)) {
                            ProjectRow(project: project, access: policy.access(for: project.id))
                        }
                        .accessibilityIdentifier("project.row")
                    }
                }
            }

            if !policy.isPro && !showArchive && env.entitlements.isDetermined {
                Section {
                    FreePlanSummary(policy: policy) { paywallTrigger = .settings }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("tab.projects"))
        .searchable(text: $search, prompt: L("projects.search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { createTapped() } label: { Label(L("projects.new"), systemImage: "plus") }
                    .accessibilityIdentifier("projects.new")
            }
        }
        .sheet(isPresented: $showCreate) { ProjectEditView(project: nil) { created in
            if let created { env.router.projectsPath.append(.project(created.id)) }
        } }
        .sheet(item: $paywallTrigger) { PaywallView(trigger: $0) }
    }

    private func createTapped() {
        // The form opens in any case; the Pro step comes on Save so the draft is never lost (U4).
        showCreate = true
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if showArchive {
            ContentUnavailableView(L("projects.archive.empty.title"), systemImage: "archivebox",
                                   description: Text(L("projects.archive.empty.message")))
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(L("projects.empty.title"), systemImage: "folder.badge.plus",
                                       description: Text(L("projects.empty.message")))
                Button(L("projects.new")) { createTapped() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
    }
}

struct UnsortedRow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var count = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("projects.unsorted")).font(.body.weight(.medium))
                Text(L("projects.unsorted.subtitle")).font(.footnote).foregroundStyle(Color.secondary)
            }
            Spacer()
            Text(verbatim: "\(count)").foregroundStyle(Color.secondary).monospacedDigit()
        }
        .frame(minHeight: Theme.minTapSize)
        .task(id: env.repository?.revision) { count = env.repository?.photoCount(projectID: nil) ?? 0 }
        .accessibilityElement(children: .combine)
    }
}

struct ProjectRow: View {
    @Environment(AppEnvironment.self) private var env
    let project: Project
    let access: AccessPolicy.ProjectAccess
    @State private var count = 0
    @State private var coverID: UUID?
    @State private var coverPath: String?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let coverID, let coverPath {
                    ThumbnailView(photoID: coverID, originalPath: coverPath)
                } else {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: "folder").foregroundStyle(Color.secondary)
                    }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(project.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                if !project.siteAddress.isEmpty {
                    Text(project.siteAddress).font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(L("project.photoCount", count))
                    if let status = statusText {
                        Label(status, systemImage: statusIcon).labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .task(id: env.repository?.revision) {
            guard let repository = env.repository else { return }
            count = repository.photoCount(projectID: project.id)
            let first = repository.photos(projectID: project.id).first
            coverID = first?.id
            coverPath = first?.originalPath
        }
    }

    private var statusText: String? {
        switch access {
        case .editable: return nil
        case .archived: return L("project.archived")
        case .readOnlyNotSelected, .readOnlyTooManyPhotos: return L("project.readOnly.short")
        }
    }

    private var statusIcon: String {
        access == .archived ? "archivebox" : "lock"
    }
}

/// Free plan usage with the explicit benefit of Pro (shown only to Free users).
struct FreePlanSummary: View {
    let policy: AccessPolicy
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("free.summary.title")).font(.subheadline.weight(.semibold))
            FreeUsageMeters(policy: policy)
            Text(L("free.quota.note")).font(.footnote).foregroundStyle(Color.secondary)
            Button(L("free.summary.upgrade"), action: onUpgrade)
                .font(.footnote.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}

/// "Photos: 2 of 3" and "Projects: 1 of 1" of the lifetime Free quota.
struct FreeUsageMeters: View {
    let policy: AccessPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageMeter(title: L("free.usage.photos", min(policy.usage.photosAdded, policy.photoQuota), policy.photoQuota),
                       used: policy.usage.photosAdded, total: policy.photoQuota)
            UsageMeter(title: L("free.usage.projects", min(policy.usage.projectsCreated, AccessPolicy.freeLifetimeProjectLimit),
                                AccessPolicy.freeLifetimeProjectLimit),
                       used: policy.usage.projectsCreated, total: AccessPolicy.freeLifetimeProjectLimit)
        }
    }
}

struct UsageMeter: View {
    let title: String
    let used: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.footnote.weight(.medium))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(used >= total ? Theme.warning : Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(min(used, total)) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
