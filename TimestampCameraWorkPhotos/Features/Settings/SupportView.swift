import PhotosUI
import SwiftUI

/// S20 support: category, message, optional diagnostics with a full preview. Every path opens only
/// on an explicit tap; with no mail app there is always a working "Copy support email".
struct SupportView: View {
    let presetCategory: SupportCategory?
    @Environment(AppEnvironment.self) private var env
    @State private var category: SupportCategory = .other
    @State private var message = ""
    @State private var includeDiagnostics = false
    @State private var showDiagnostics = false
    @State private var attachmentItem: PhotosPickerItem?
    @State private var attachment: Data?
    @State private var showMail = false
    @State private var toast: ToastMessage?
    @State private var loaded = false

    var body: some View {
        let config = env.config
        let diagnostics = Diagnostics.collect(category: category, files: env.files)
        Form {
            Section {
                Picker(L("support.category"), selection: $category) {
                    ForEach(SupportCategory.allCases) { Text(L($0.titleKey)).tag($0) }
                }
                LimitedTextField(L("support.message.placeholder"), text: $message, limit: TextLimits.supportMessage,
                                 axis: .vertical, lines: 4...10)
            } footer: {
                Text(L("support.message.footer"))
            }

            Section {
                Toggle(L("support.diagnostics.include"), isOn: $includeDiagnostics)
                DisclosureGroup(L("support.diagnostics.preview"), isExpanded: $showDiagnostics) {
                    Text(diagnostics.text).font(.footnote.monospaced()).textSelection(.enabled)
                }
            } footer: {
                Text(L("support.diagnostics.footer"))
            }

            if MailComposeView.canSendMail && config.supportEmail != nil {
                Section {
                    PhotosPicker(selection: $attachmentItem, matching: .images) {
                        Label(attachment == nil ? L("support.attach") : L("support.attach.change"), systemImage: "paperclip")
                    }
                    if attachment != nil {
                        Button(L("support.attach.remove"), role: .destructive) { attachment = nil }
                    }
                } footer: {
                    Text(L("support.attach.footer"))
                }
            }

            Section {
                if let email = config.supportEmail {
                    if MailComposeView.canSendMail {
                        Button { showMail = true } label: { Label(L("support.sendMail"), systemImage: "envelope") }
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if let url = SupportComposer.mailtoURL(email: email, subject: SupportComposer.subject(category: category),
                                                                  body: SupportComposer.body(message: message, diagnostics: includeDiagnostics ? diagnostics : nil)) {
                        Button {
                            ExternalLink.open(url) { accepted in
                                if !accepted { toast = ToastMessage(text: L("support.noMailApp"), kind: .info) }
                            }
                        } label: { Label(L("support.openMailApp"), systemImage: "envelope") }
                    }
                    Button {
                        UIPasteboard.general.string = email
                        toast = ToastMessage(text: L("support.copied"), kind: .success)
                    } label: {
                        // The address is shown on one line: wrapping would hyphenate it ("in-valid").
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("support.copyEmail"))
                            Text(verbatim: email)
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        .frame(minHeight: Theme.minTapSize, alignment: .leading)
                    }
                } else {
                    Label(L("support.notConfigured"), systemImage: "exclamationmark.triangle").font(.footnote)
                }
                if let form = config.supportFormURL {
                    // Opened without any parameters: no user data in the URL.
                    Button { ExternalLink.open(form) } label: { Label(L("support.openForm"), systemImage: "safari") }
                }
                NavigationLink(L("help.title")) { HelpView() }
            }
        }
        .navigationTitle(L("support.title"))
        .toast($toast)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let presetCategory { category = presetCategory }
            env.analytics.track(.supportOpened(source: .settings))
        }
        .onChange(of: attachmentItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = ImageLoader.orientedImage(data: data, maxPixel: 2000),
                   let jpeg = ImageLoader.jpegData(image, quality: 0.8) {
                    // Re-encoded without metadata (no GPS) before attaching.
                    attachment = jpeg
                }
                attachmentItem = nil
            }
        }
        .sheet(isPresented: $showMail) {
            if let email = config.supportEmail {
                MailComposeView(recipient: email, subject: SupportComposer.subject(category: category),
                                body: SupportComposer.body(message: message, diagnostics: includeDiagnostics ? diagnostics : nil),
                                attachments: attachment.map { [($0, "image/jpeg", "attachment.jpg")] } ?? []) { result in
                    if result == .sent { toast = ToastMessage(text: L("support.sent"), kind: .success) }
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// S21 help articles.
struct HelpView: View {
    private let topics = ["location", "import", "missingDate", "largePDF", "restore", "offline", "proof"]

    var body: some View {
        List {
            ForEach(topics, id: \.self) { topic in
                DisclosureGroup {
                    Text(L("help.\(topic).body")).font(.subheadline).foregroundStyle(Color.secondary).padding(.vertical, 4)
                } label: {
                    Text(L("help.\(topic).title")).font(.body.weight(.medium))
                }
            }
        }
        .navigationTitle(L("help.title"))
    }
}
