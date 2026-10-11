import PhotosUI
import SwiftData
import SwiftUI

struct SettingsTab: View {
    var body: some View {
        NavigationStack {
            SettingsView()
        }
    }
}

/// S16 settings. Pickers edit local state that is written to `AppPreferences` on change.
/// External links go through `ExternalLink`, never `@Environment(\.openURL)` (iOS 17.0–17.1 hang).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(InterfaceLanguage.defaultsKey) private var interfaceLanguage = ""
    @State private var theme: ThemePreference = .system
    @State private var reportLanguage: AppLanguage = .en
    @State private var pageSize: PageSize = .a4
    @State private var loaded = false
    @State private var showPaywall = false

    var body: some View {
        let store = env.entitlements
        Form {
            Section {
                ProStatusBanner { showPaywall = true }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker(L("settings.language"), selection: $interfaceLanguage) {
                    Text(L("settings.language.system")).tag("")
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0.rawValue) }
                }
                Picker(L("settings.theme"), selection: $theme) {
                    Text(L("settings.theme.system")).tag(ThemePreference.system)
                    Text(L("settings.theme.light")).tag(ThemePreference.light)
                    Text(L("settings.theme.dark")).tag(ThemePreference.dark)
                }
                NavigationLink(L("settings.defaultStamp")) { DefaultStampSettingsView(showsDoneButton: false) }
                    .accessibilityIdentifier("settings.defaultStamp")
            } header: {
                Text(L("settings.general"))
            } footer: {
                Text(L("settings.language.footer"))
            }

            Section {
                Picker(L("settings.reportLanguage"), selection: $reportLanguage) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                }
                Picker(L("settings.pageSize"), selection: $pageSize) {
                    Text(L("report.pageSize.a4")).tag(PageSize.a4)
                    Text(L("report.pageSize.letter")).tag(PageSize.letter)
                }
            } header: {
                Text(L("settings.reports"))
            } footer: {
                Text(L("settings.reports.footer"))
            }

            Section(L("settings.profileSection")) {
                NavigationLink(L("profile.title")) { ProfileView() }
                    .accessibilityIdentifier("settings.profile")
                NavigationLink {
                    BrandPresetsView()
                } label: {
                    HStack {
                        Text(L("brand.title"))
                        if !store.isPro { Spacer(); Text(verbatim: "Pro").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor) }
                    }
                }
                .accessibilityIdentifier("settings.brandPresets")
            }

            Section(L("settings.data")) {
                NavigationLink(L("privacy.title")) { PrivacyStorageView() }
                    .accessibilityIdentifier("settings.privacy")
                NavigationLink(L("backup.title")) { BackupsView() }
                    .accessibilityIdentifier("settings.backups")
            }

            Section(L("settings.help")) {
                NavigationLink(L("support.title")) { SupportView(presetCategory: nil) }
                    .accessibilityIdentifier("settings.support")
                NavigationLink(L("help.title")) { HelpView() }
                    .accessibilityIdentifier("settings.help")
            }

            Section(L("settings.documents")) {
                if let url = env.config.privacyPolicyURL {
                    Button(L("paywall.privacy")) { ExternalLink.open(url) }
                }
                if let url = env.config.termsURL {
                    Button(L("paywall.terms")) { ExternalLink.open(url) }
                }
                if env.config.privacyPolicyURL == nil || env.config.termsURL == nil {
                    Text(L("config.documentsMissing")).font(.footnote).foregroundStyle(Color.secondary)
                }
                LabeledContent(L("settings.version"), value: "\(AppInfo.version) (\(AppInfo.build))")
            }

            if env.config.environment == .development && !env.config.isReleaseReady {
                Section {
                    Label(L("config.devWarning", env.config.missingReleaseItems.joined(separator: ", ")), systemImage: "hammer")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .navigationTitle(L("tab.settings"))
        .sheet(isPresented: $showPaywall) { PaywallView(trigger: .settings) }
        .onAppear(perform: load)
        .onChange(of: theme) { _, value in update(\.theme, value) }
        .onChange(of: reportLanguage) { _, value in update(\.reportLanguage, value) }
        .onChange(of: pageSize) { _, value in update(\.defaultPageSize, value) }
    }

    private func load() {
        guard !loaded, let repository = env.repository else { return }
        let prefs = repository.preferences()
        theme = prefs.theme
        reportLanguage = prefs.reportLanguage
        pageSize = prefs.defaultPageSize
        loaded = true
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppPreferences, Value>, _ value: Value) {
        guard loaded, let repository = env.repository else { return }
        let prefs = repository.preferences()
        guard prefs[keyPath: keyPath] != value else { return }
        prefs[keyPath: keyPath] = value
        try? repository.save()
    }
}

/// S17 executor profile: everything optional. The logo appears in reports with Pro only.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""
    @State private var contact = ""
    @State private var logoItem: PhotosPickerItem?
    @State private var logoImage: UIImage?
    @State private var loaded = false
    @State private var error: AppError?

    var body: some View {
        Form {
            Section {
                LimitedTextField(L("profile.name"), text: $name, limit: TextLimits.executorName)
                LimitedTextField(L("profile.contact"), text: $contact, limit: TextLimits.contactText, axis: .vertical)
            } footer: {
                Text(L("profile.footer"))
            }
            Section {
                if let logoImage {
                    Image(uiImage: logoImage).resizable().scaledToFit().frame(maxHeight: 80)
                }
                PhotosPicker(selection: $logoItem, matching: .images) {
                    Label(logoImage == nil ? L("profile.logo.add") : L("profile.logo.change"), systemImage: "photo")
                }
                if logoImage != nil {
                    Button(L("profile.logo.remove"), role: .destructive) { removeLogo() }
                }
            } header: {
                Text(L("profile.logo"))
            } footer: {
                Text(env.entitlements.isPro ? L("profile.logo.footerPro") : L("profile.logo.footerFree"))
            }
        }
        .navigationTitle(L("profile.title"))
        .accessibilityIdentifier("screen.profile")
        .errorAlert($error)
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { await importLogo(item) }
        }
    }

    private func load() {
        guard !loaded, let repository = env.repository else { return }
        loaded = true
        let prefs = repository.preferences()
        name = prefs.executorName
        contact = prefs.executorContact
        logoImage = LogoStore.image(path: prefs.executorLogoPath, files: env.files)
    }

    private func save() {
        guard let repository = env.repository else { return }
        let prefs = repository.preferences()
        prefs.executorName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.executorContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        try? repository.save()
    }

    private func importLogo(_ item: PhotosPickerItem) async {
        guard let repository = env.repository else { return }
        do {
            let path = try await LogoStore.importLogo(item, files: env.files)
            let prefs = repository.preferences()
            if let old = prefs.executorLogoPath { env.files.removeItem(relative: old) }
            prefs.executorLogoPath = path
            try repository.save()
            logoImage = LogoStore.image(path: path, files: env.files)
        } catch {
            self.error = AppError.wrap(error, default: .importLoadFailed)
        }
        logoItem = nil
    }

    private func removeLogo() {
        guard let repository = env.repository else { return }
        let prefs = repository.preferences()
        if let old = prefs.executorLogoPath { env.files.removeItem(relative: old) }
        prefs.executorLogoPath = nil
        try? repository.save()
        logoImage = nil
    }
}

/// Logos are imported through the system picker, downsampled to 600 px and stored as PNG.
enum LogoStore {
    static func importLogo(_ item: PhotosPickerItem, files: FileStore) async throws -> String {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw AppError(.importLoadFailed) }
        guard data.count <= Int(ImportLimits.maxFileBytes) else { throw AppError(.importFileTooLarge, arguments: ["100 MB"]) }
        _ = try ImageInspector.inspect(data: data)
        guard let image = ImageLoader.orientedImage(data: data, maxPixel: 600) else { throw AppError(.importCorrupted) }
        guard let png = UIImage(cgImage: image).pngData() else { throw AppError(.importCorrupted) }
        let path = FileStore.logoRelativePath(id: UUID())
        try files.writeAtomically(png, toRelative: path)
        return path
    }

    static func image(path: String?, files: FileStore) -> UIImage? {
        guard let path, let url = try? files.url(forRelative: path), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

/// Pro brand presets (up to 10) for reports.
struct BrandPresetsView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \BrandPreset.createdAt) private var presets: [BrandPreset]
    @State private var editing: BrandPresetEditRequest?
    @State private var showPaywall = false

    var body: some View {
        let isPro = env.entitlements.isPro
        List {
            Section {
                Text(L("brand.explanation", AccessPolicy.brandPresetLimit)).font(.footnote).foregroundStyle(Color.secondary)
            }
            if !isPro {
                Section {
                    Button { showPaywall = true } label: { Label(L("report.branding.pro"), systemImage: "star") }
                }
            }
            Section {
                ForEach(presets) { preset in
                    Button { editing = BrandPresetEditRequest(presetID: preset.id) } label: {
                        VStack(alignment: .leading) {
                            Text(preset.title.isEmpty ? L("brand.untitled") : preset.title).foregroundStyle(Color.primary)
                            Text([preset.executorName, preset.contactText].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
                        }
                    }
                    .disabled(!isPro)
                }
                .onDelete { indexes in
                    for index in indexes { try? env.repository?.deleteBrandPreset(presets[index]) }
                }
                if isPro {
                    Button { editing = BrandPresetEditRequest(presetID: nil) } label: { Label(L("brand.new"), systemImage: "plus") }
                        .disabled(presets.count >= AccessPolicy.brandPresetLimit)
                }
            } footer: {
                if presets.count >= AccessPolicy.brandPresetLimit { Text(L("brand.limitReached", AccessPolicy.brandPresetLimit)) }
            }
        }
        .navigationTitle(L("brand.title"))
        .accessibilityIdentifier("screen.brandPresets")
        .sheet(item: $editing) { request in BrandPresetEditView(presetID: request.presetID) }
        .sheet(isPresented: $showPaywall) { PaywallView(trigger: .brandPresets) }
    }
}

struct BrandPresetEditRequest: Identifiable {
    let id = UUID()
    let presetID: UUID?
}

struct BrandPresetEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let presetID: UUID?
    @State private var title = ""
    @State private var name = ""
    @State private var contact = ""
    @State private var logoPath: String?
    @State private var logoItem: PhotosPickerItem?
    @State private var error: AppError?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LimitedTextField(L("brand.field.title"), text: $title, limit: TextLimits.presetTitle)
                    LimitedTextField(L("profile.name"), text: $name, limit: TextLimits.executorName)
                    LimitedTextField(L("profile.contact"), text: $contact, limit: TextLimits.contactText, axis: .vertical)
                }
                Section(L("profile.logo")) {
                    if let image = LogoStore.image(path: logoPath, files: env.files) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 80)
                    }
                    PhotosPicker(selection: $logoItem, matching: .images) {
                        Label(logoPath == nil ? L("profile.logo.add") : L("profile.logo.change"), systemImage: "photo")
                    }
                    if logoPath != nil { Button(L("profile.logo.remove"), role: .destructive) { logoPath = nil } }
                }
            }
            .navigationTitle(presetID == nil ? L("brand.new") : L("brand.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($error)
            .onChange(of: logoItem) { _, item in
                guard let item else { return }
                Task {
                    do { logoPath = try await LogoStore.importLogo(item, files: env.files) }
                    catch { self.error = AppError.wrap(error, default: .importLoadFailed) }
                    logoItem = nil
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let preset = env.repository?.brandPreset(id: presetID) {
                title = preset.title
                name = preset.executorName
                contact = preset.contactText
                logoPath = preset.logoPath
            }
        }
    }

    private func save() {
        guard let repository = env.repository else { return }
        do {
            if let preset = repository.brandPreset(id: presetID) {
                try repository.updateBrandPreset(preset, title: title, executorName: name, contactText: contact, logoPath: logoPath)
            } else {
                try repository.createBrandPreset(title: title, executorName: name, contactText: contact, logoPath: logoPath)
            }
            dismiss()
        } catch {
            self.error = AppError.wrap(error, default: .databaseSaveFailed)
        }
    }
}
