import SwiftUI

/// S07 create / edit project. Only the title is required; no contacts access is requested.
/// When Free already has its project, Save shows Pro; closing or cancelling the purchase keeps the draft (U4).
struct ProjectEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    var onSaved: (Project?) -> Void = { _ in }

    @State private var draft = ProjectDraft()
    @State private var hasWorkDate = false
    @State private var loaded = false
    @State private var paywallTrigger: PaywallTrigger?
    @State private var error: AppError?
    @State private var showArchiveHint = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LimitedTextField(L("project.field.title"), text: $draft.title, limit: TextLimits.projectTitle)
                        .accessibilityIdentifier("project.field.title")
                } header: {
                    Text(L("project.field.title.header"))
                } footer: {
                    Text(L("project.field.required"))
                }
                Section(L("project.field.details")) {
                    LimitedTextField(L("project.field.site"), text: $draft.siteAddress, limit: TextLimits.siteAddress, axis: .vertical)
                    LimitedTextField(L("project.field.client"), text: $draft.clientName, limit: TextLimits.clientName)
                    Toggle(L("project.field.workDate"), isOn: $hasWorkDate)
                    if hasWorkDate {
                        DatePicker(L("project.field.workDate"), selection: Binding(get: { draft.workDate ?? Date() },
                                                                                  set: { draft.workDate = $0 }),
                                   displayedComponents: .date)
                    }
                }
                Section(L("project.field.notes")) {
                    LimitedTextField(L("project.field.notes.placeholder"), text: $draft.notes, limit: TextLimits.projectNotes,
                                     axis: .vertical, lines: 3...8)
                }
                if project == nil && requiresPro {
                    Section {
                        Label(L("project.create.proHint"), systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .navigationTitle(project == nil ? L("project.new.title") : L("project.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }.accessibilityIdentifier("project.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(project == nil ? L("common.create") : L("common.save")) { save() }
                        .disabled(!draft.isValid)
                        .accessibilityIdentifier("project.save")
                }
            }
            .sheet(item: $paywallTrigger) { trigger in
                PaywallView(trigger: trigger)
            }
            .errorAlert($error)
        }
        .interactiveDismissDisabled(isDirty)
        .onAppear {
            guard !loaded else { return }
            if let project {
                draft = ProjectDraft(project: project)
                hasWorkDate = draft.workDate != nil
            }
            loaded = true
        }
    }

    private var requiresPro: Bool {
        !env.policy().canCreateProject
    }

    private var isDirty: Bool {
        if let project { return draft != ProjectDraft(project: project) }
        return !draft.trimmedTitle.isEmpty || !draft.siteAddress.isEmpty || !draft.clientName.isEmpty || !draft.notes.isEmpty
    }

    private func save() {
        guard let repository = env.repository else { return }
        var final = draft
        if !hasWorkDate { final.workDate = nil }
        do {
            if let project {
                try repository.update(project, with: final)
                onSaved(project)
                dismiss()
                return
            }
            let policy = env.policy()
            guard policy.canCreateProject else {
                paywallTrigger = .secondProject
                return
            }
            let created = try repository.createProject(final, makeFreeProject: !policy.isPro)
            env.analytics.track(.projectCreated)
            onSaved(created)
            dismiss()
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }
}

/// Text field that enforces a character limit and shows the count near the limit.
struct LimitedTextField: View {
    let title: String
    @Binding var text: String
    let limit: Int
    var axis: Axis = .horizontal
    var lines: ClosedRange<Int> = 1...4

    init(_ title: String, text: Binding<String>, limit: Int, axis: Axis = .horizontal, lines: ClosedRange<Int> = 1...4) {
        self.title = title
        self._text = text
        self.limit = limit
        self.axis = axis
        self.lines = lines
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(title, text: $text, axis: axis)
                .lineLimit(axis == .vertical ? lines : 1...1)
                .onChange(of: text) { _, value in
                    if value.count > limit { text = String(value.prefix(limit)) }
                }
            if text.count > limit * 8 / 10 {
                Text(verbatim: "\(text.count)/\(limit)")
                    .font(.caption2)
                    .foregroundStyle(text.count >= limit ? Theme.warning : .secondary)
                    .monospacedDigit()
            }
        }
    }
}
