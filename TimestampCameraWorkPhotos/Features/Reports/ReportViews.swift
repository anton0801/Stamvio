import SwiftData
import SwiftUI

/// S13 generation: progress, cancel, error and retry. Never blocks navigation forever.
struct ReportGenerationView: View {
    let job: ReportGenerationJob
    let onEdit: () -> Void
    let onDone: () -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch job.phase {
            case .preparing:
                progress(L("report.generation.preparing"), value: nil)
            case let .rendering(done, total):
                progress(L("report.generation.page", done, total), value: total > 0 ? Double(done) / Double(total) : nil)
            case .verifying:
                progress(L("report.generation.verifying"), value: 1)
            case .ready(let output):
                PDFResultView(output: output, onEdit: onEdit, onDone: onDone)
            case .failed(let error):
                outcome(icon: "exclamationmark.triangle", title: L("report.generation.failed"), message: error.displayMessage)
            case .cancelled:
                outcome(icon: "xmark.circle", title: L("report.generation.cancelled"), message: L("report.generation.cancelled.message"))
            }
        }
        .navigationBarBackButtonHidden(job.isRunning)
    }

    private func progress(_ text: String, value: Double?) -> some View {
        VStack(spacing: 16) {
            if let value {
                ProgressView(value: value)
                    .accessibilityLabel(L("report.generation.a11y"))
                    .accessibilityValue(text)
            } else {
                ProgressView()
            }
            Text(text).font(.headline).multilineTextAlignment(.center)
            Text(L("report.generation.hint")).font(.footnote).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
            Button(L("common.cancel"), role: .cancel) { job.cancel() }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("report.generation.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func outcome(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Color.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(Color.secondary)
            Text(L("report.generation.dataKept")).font(.footnote).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
            HStack {
                Button(L("report.editSettings"), action: onEdit).buttonStyle(.bordered)
                Button(L("common.retry")) { job.retry() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("report.generation.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// S12 PDF: page preview, real file size, Share, Save to Files, edit settings.
struct PDFResultView: View {
    let output: ReportGenerationJob.Output
    let onEdit: () -> Void
    let onDone: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var share: ShareRequest?
    @State private var saveRequest: ExportFilesRequest?
    @State private var paywallTrigger: PaywallTrigger?
    @State private var toast: ToastMessage?

    var body: some View {
        VStack(spacing: 0) {
            if output.isPreview {
                InfoBanner(icon: "star", title: L("report.preview.title"), message: L("report.preview.message"),
                           actions: [(L("paywall.unlock"), { paywallTrigger = .beforeAfterExport })])
                    .padding(12)
                    .accessibilityIdentifier("report.previewBanner")
            } else {
                Label(L("report.ready"), systemImage: "checkmark.seal.fill")
                    .accessibilityIdentifier("report.ready")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.success)
                    .padding(.top, 10)
            }
            Text(L("report.fileInfo", output.pageCount, ByteFormatting.string(output.bytes)))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .padding(.bottom, 6)
            PDFKitView(url: output.url)
                .accessibilityLabel(L("report.preview.a11y"))
        }
        .navigationTitle(output.isPreview ? L("report.preview.navTitle") : L("report.navTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("report.editSettings"), action: onEdit) }
            ToolbarItem(placement: .confirmationAction) { Button(L("common.done"), action: onDone).accessibilityIdentifier("report.done") }
        }
        .safeAreaInset(edge: .bottom) {
            if !output.isPreview {
                HStack(spacing: 12) {
                    Button {
                        env.analytics.track(.shareSheetOpened(source: .report))
                        share = ShareRequest(items: [output.url], source: .report)
                    } label: {
                        Label(L("export.share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { saveRequest = ExportFilesRequest(urls: [output.url]) } label: {
                        Label(L("export.saveFiles"), systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            } else {
                Button { paywallTrigger = .beforeAfterExport } label: {
                    Label(L("report.exportPro"), systemImage: "lock").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .sheet(item: $share) { request in
            // Closing the share sheet keeps the PDF and is not a delivery.
            ShareSheet(items: request.items) { completed in
                if completed { env.analytics.track(.shareCompleted(source: .report)) }
            }
        }
        .sheet(item: $saveRequest) { request in
            DocumentExportPicker(urls: request.urls) { saved in
                if saved { toast = ToastMessage(text: L("export.saved"), kind: .success) }
            }
        }
        .sheet(item: $paywallTrigger, onDismiss: {
            // After a verified purchase the user goes back to the settings and confirms the export.
            if env.entitlements.isPro && output.isPreview { onEdit() }
        }) { PaywallView(trigger: $0) }
        .toast($toast)
        .onAppear { env.analytics.track(.reportPreviewed(template: output.template)) }
    }
}

/// Reports tab of a project: saved versions are always available to re-send, even without Pro.
struct ReportsListSection: View {
    let project: Project
    let reports: [ReportVersion]
    let photosCount: Int
    let canCreate: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reports.isEmpty {
                ContentUnavailableView(L("reports.empty.title"), systemImage: "doc.richtext",
                                       description: Text(L("reports.empty.message")))
            } else {
                Text(L("reports.footer")).font(.footnote).foregroundStyle(Color.secondary)
            }
            ForEach(reports) { report in
                NavigationLink(value: ProjectsRoute.report(report.id)) {
                    ReportRow(report: report)
                }
                .buttonStyle(.plain)
            }
            Button(action: onCreate) {
                Label(L("report.create"), systemImage: "plus").frame(maxWidth: .infinity, minHeight: Theme.minTapSize)
            }
            .buttonStyle(.bordered)
            .disabled(!canCreate)
        }
    }
}

struct ReportRow: View {
    let report: ReportVersion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: report.status == .ready ? "doc.richtext" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(report.status == .ready ? Color.accentColor : Theme.warning)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(report.createdAt.appFormatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.secondary)
                Text(details).font(.caption).foregroundStyle(Color.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let template = report.template == .standard ? L("report.template.standard") : L("report.template.beforeAfter")
        var parts = [template, report.language.nativeName, report.pageSize == .a4 ? "A4" : "Letter",
                     L("report.pages", report.pageCount), ByteFormatting.string(report.bytes)]
        if report.status == .missingFile { parts.append(L("report.missingFile")) }
        return parts.joined(separator: " · ")
    }
}

/// A saved report version: re-send or save at any time (also after Pro ended).
struct SavedReportView: View {
    let reportID: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var reports: [ReportVersion]
    @State private var share: ShareRequest?
    @State private var saveRequest: ExportFilesRequest?
    @State private var confirmDelete = false
    @State private var toast: ToastMessage?

    init(reportID: UUID) {
        self.reportID = reportID
        _reports = Query(filter: #Predicate<ReportVersion> { $0.id == reportID })
    }

    var body: some View {
        if let report = reports.first, let url = try? env.files.url(forRelative: report.pdfPath) {
            VStack(spacing: 0) {
                Text(L("report.fileInfo", report.pageCount, ByteFormatting.string(report.bytes)))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .padding(6)
                if report.status == .ready && FileManager.default.fileExists(atPath: url.path) {
                    PDFKitView(url: url)
                } else {
                    ContentUnavailableView(L("report.missingFile"), systemImage: "exclamationmark.triangle",
                                           description: Text(L("report.missingFile.message")))
                }
            }
            .navigationTitle(report.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("common.delete"), systemImage: "trash") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if report.status == .ready {
                    HStack(spacing: 12) {
                        Button {
                            env.analytics.track(.shareSheetOpened(source: .report))
                            share = ShareRequest(items: [url], source: .report)
                        } label: {
                            Label(L("export.share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { saveRequest = ExportFilesRequest(urls: [url]) } label: {
                            Label(L("export.saveFiles"), systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .sheet(item: $share) { request in
                ShareSheet(items: request.items) { completed in
                    if completed { env.analytics.track(.shareCompleted(source: .report)) }
                }
            }
            .sheet(item: $saveRequest) { request in
                DocumentExportPicker(urls: request.urls) { saved in
                    if saved { toast = ToastMessage(text: L("export.saved"), kind: .success) }
                }
            }
            .confirmationDialog(L("report.delete.title"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("report.delete.confirm"), role: .destructive) {
                    try? env.repository?.deleteReport(report)
                    dismiss()
                }
            } message: {
                Text(L("report.delete.message"))
            }
            .toast($toast)
        } else {
            ContentUnavailableView(L("report.notFound"), systemImage: "doc")
        }
    }
}
