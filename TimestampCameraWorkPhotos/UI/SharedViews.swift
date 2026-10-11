import MessageUI
import PDFKit
import SwiftUI
import UIKit

// MARK: - Theme

enum Theme {
    static let success = Color.green
    static let destructive = Color.red
    static let warning = Color.orange
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let minTapSize: CGFloat = 44
}

// MARK: - Thumbnails

struct ThumbnailView: View {
    @Environment(AppEnvironment.self) private var env
    let photoID: UUID
    let originalPath: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        // The rectangle takes the proposed size; the image fills it and is clipped to it.
        Rectangle()
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(Color.secondary)
                }
            }
            .clipped()
            .contentShape(Rectangle())
        .task(id: photoID) {
            if let cached = env.thumbnails.cached(photoID) {
                image = cached
                return
            }
            image = await env.thumbnails.thumbnail(photoID: photoID, originalRelativePath: originalPath)
        }
    }
}

/// Grid cell with provenance and status marks that do not rely on color alone.
struct PhotoCell: View {
    let photo: PhotoRecord
    var index: Int?
    var pairRole: String?
    var isSelected = false
    var isSelecting = false

    var body: some View {
        ThumbnailView(photoID: photo.id, originalPath: photo.originalPath)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    if photo.isImported { badge("square.and.arrow.down") }
                    if photo.hasManualDate { badge("pencil") }
                    if photo.dateInfo.kind == .unavailable { badge("clock.badge.questionmark") }
                    if let role = pairRole { textBadge(role) }
                }
                .padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.saveState == .missingFile {
                    badge("exclamationmark.triangle.fill").padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.25)))
                        .padding(5)
                }
            }
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 3) }
            }
            // Badges stay small enough not to cover the photo; VoiceOver reads them in full.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelecting ? (isSelected ? [.isButton, .isSelected] : .isButton) : .isButton)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(.black.opacity(0.55)))
    }

    private func textBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.6)))
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let index { parts.append(L("a11y.photo.number", index)) }
        let caption = photo.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { parts.append(caption) }
        if photo.isImported { parts.append(L("provenance.photo.imported")) }
        if photo.hasManualDate { parts.append(L("provenance.time.manual")) }
        if photo.dateInfo.kind == .unavailable { parts.append(L("provenance.time.unavailable")) }
        if let pairRole { parts.append(pairRole) }
        if photo.saveState == .missingFile { parts.append(L("photo.missingFile")) }
        if isSelecting { parts.append(isSelected ? L("a11y.selected") : L("a11y.notSelected")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Share sheet (system), with completion

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// `true` only for a positive callback of the system share flow (not proof of delivery).
    var onComplete: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    let source: AnalyticsSource
}

// MARK: - Save to Files

struct DocumentExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    var onComplete: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Bool) -> Void
        init(onComplete: @escaping (Bool) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onComplete(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onComplete(false) }
    }
}

struct ExportFilesRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Mail

struct MailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    var attachments: [(Data, String, String)] = []
    var onFinish: (MFMailComposeResult) -> Void = { _ in }

    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        for (data, mime, name) in attachments { controller.addAttachmentData(data, mimeType: mime, fileName: name) }
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

// MARK: - PDF

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = .systemGroupedBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url { uiView.document = PDFDocument(url: url) }
    }
}

// MARK: - Errors and toasts

extension View {
    /// Alert with a localized message and the technical code (never a stack trace).
    func errorAlert(_ error: Binding<AppError?>) -> some View {
        alert(L("error.title"), isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button(L("common.ok"), role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue?.displayMessage ?? "")
        }
    }

    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

struct ToastMessage: Equatable, Identifiable {
    enum Kind { case success, info, error }
    let id = UUID()
    let text: String
    var kind: Kind = .info
}

private struct ToastModifier: ViewModifier {
    @Binding var message: ToastMessage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: icon(message.kind))
                        .foregroundStyle(color(message.kind))
                    Text(message.text)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .task(id: message.id) {
                    UIAccessibility.post(notification: .announcement, argument: message.text)
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if self.message?.id == message.id { self.message = nil }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: message)
    }

    private func icon(_ kind: ToastMessage.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .success: return Theme.success
        case .info: return .accentColor
        case .error: return Theme.destructive
        }
    }
}

/// Banner for read-only / archived states and limits. Text + icon, not color alone.
struct InfoBanner: View {
    let icon: String
    let title: String
    var message: String?
    var tint: Color = .accentColor
    var actions: [(String, () -> Void)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let message { Text(message).font(.footnote).foregroundStyle(Color.secondary) }
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            if !actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { actionButtons }
                    VStack(alignment: .leading) { actionButtons }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
    }

    @ViewBuilder private var actionButtons: some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button(action.0, action: action.1)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// IMP-01: limits and the remaining room are shown before the system picker opens — the first time,
/// and whenever the target has fewer free slots than one import batch (e.g. a Free project).
struct ImportLimitsDialog: ViewModifier {
    @Binding var isPresented: Bool
    let remaining: Int?
    let onChoose: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(L("import.limits.title"), isPresented: $isPresented, titleVisibility: .visible) {
            Button(L("import.limits.choose")) {
                ImportLimitsDialog.markSeen()
                onChoose()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private var message: String {
        var text = L("import.limits.message", AccessPolicy.importBatchLimit)
        if let remaining { text += "\n" + L("import.limits.remaining", remaining) }
        return text
    }

    private static let seenKey = "import.limitsSeen"

    static func shouldShow(remaining: Int?) -> Bool {
        if !UserDefaults.standard.bool(forKey: seenKey) { return true }
        if let remaining, remaining < AccessPolicy.importBatchLimit { return true }
        return false
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }
}

/// Opens an external link (documents, support form, mail app).
///
/// Deliberately not `@Environment(\.openURL)`: on iOS 17.0–17.1 a view that reads that environment
/// value and contains navigation links re-renders endlessly as soon as a screen is pushed from it —
/// the UI freezes and memory grows. Found on an iPhone 13 Pro with iOS 17.1.2 (fixed by Apple in 17.2).
@MainActor
enum ExternalLink {
    static func open(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        UIApplication.shared.open(url, options: [:]) { accepted in completion?(accepted) }
    }
}

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
