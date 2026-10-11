import SwiftData
import SwiftUI

/// S04 stamp: fields, one of 3 presets, size, position and a live preview rendered with the same
/// StampRenderer as the exported file.
struct StampSettingsEditor: View {
    @Binding var settings: StampSettings
    let previewInput: StampInput
    var previewImage: CGImage?

    var body: some View {
        Section {
            StampPreviewImage(settings: settings, input: previewInput, baseImage: previewImage)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        } footer: {
            Text(L("stamp.preview.footer"))
        }

        Section(L("stamp.preset")) {
            Picker(L("stamp.preset"), selection: Binding(get: { settings.preset }, set: { preset in
                if let fields = preset.fields { settings.fields = fields }
            })) {
                Text(L("stamp.preset.compact")).tag(StampPreset.compact)
                Text(L("stamp.preset.work")).tag(StampPreset.work)
                Text(L("stamp.preset.location")).tag(StampPreset.location)
                if settings.preset == .custom { Text(L("stamp.preset.custom")).tag(StampPreset.custom) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section(L("stamp.fields")) {
            Toggle(L("stamp.field.dateTime"), isOn: $settings.fields.dateTime)
            Toggle(L("stamp.field.project"), isOn: $settings.fields.projectName)
            Toggle(L("stamp.field.address"), isOn: $settings.fields.address)
            Toggle(L("stamp.field.coordinates"), isOn: $settings.fields.coordinates)
            Toggle(L("stamp.field.caption"), isOn: $settings.fields.caption)
        }

        Section {
            Picker(L("stamp.size"), selection: $settings.size) {
                Text(L("stamp.size.small")).tag(StampSize.small)
                Text(L("stamp.size.medium")).tag(StampSize.medium)
                Text(L("stamp.size.large")).tag(StampSize.large)
            }
            .pickerStyle(.segmented)
            StampPositionPicker(position: $settings.position)
        } header: {
            Text(L("stamp.appearance"))
        }

        Section(L("stamp.format")) {
            Picker(L("stamp.dateStyle"), selection: $settings.dateStyle) {
                Text(L("stamp.dateStyle.long")).tag(DateStyleOption.long)
                Text(L("stamp.dateStyle.iso")).tag(DateStyleOption.iso)
            }
            Picker(L("stamp.timeFormat"), selection: $settings.timeFormat) {
                Text(L("format.time.system")).tag(TimeFormatOption.system)
                Text(L("format.time.h12")).tag(TimeFormatOption.h12)
                Text(L("format.time.h24")).tag(TimeFormatOption.h24)
            }
        }
    }
}

struct StampPositionPicker: View {
    @Binding var position: StampPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("stamp.position"))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    cell(.topLeft)
                    cell(.topRight)
                }
                GridRow {
                    cell(.bottomLeft)
                    cell(.bottomRight)
                }
            }
            .frame(maxWidth: 220)
        }
        .padding(.vertical, 4)
    }

    private func cell(_ value: StampPosition) -> some View {
        Button { position = value } label: {
            RoundedRectangle(cornerRadius: 6)
                .stroke(position == value ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: position == value ? 2 : 1)
                .frame(height: 44)
                .overlay(alignment: alignment(value)) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(position == value ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 26, height: 10)
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("stamp.position.\(value.rawValue)"))
        .accessibilityAddTraits(position == value ? .isSelected : [])
    }

    private func alignment(_ value: StampPosition) -> Alignment {
        switch value {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

/// Renders the stamp on a sample (or the photo itself) with the final renderer.
struct StampPreviewImage: View {
    let settings: StampSettings
    let input: StampInput
    var baseImage: CGImage?
    var includeLocation = true

    @State private var rendered: UIImage?
    @State private var overflow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color(.tertiarySystemFill))
                if let rendered {
                    Image(uiImage: rendered).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(baseImage.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L("stamp.preview.a11y"))
            if overflow {
                Label(L("stamp.overflow.message"), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .task(id: RenderKey(settings: settings, input: input, includeLocation: includeLocation, hasBase: baseImage != nil)) {
            let base = baseImage ?? SampleImage.make()
            let lines = StampContentBuilder.lines(input: input, settings: settings, language: .current, includeLocation: includeLocation)
            let layout = StampRenderer.layout(lines: lines, settings: settings, imageSize: CGSize(width: base.width, height: base.height))
            overflow = layout?.overflow ?? false
            if let image = try? StampRenderer.render(image: base, lines: lines, settings: settings, allowOverflow: true) {
                rendered = UIImage(cgImage: image)
            }
        }
    }

    private struct RenderKey: Hashable {
        let settings: StampSettings
        let input: StampInput
        let includeLocation: Bool
        let hasBase: Bool
    }
}

extension StampSettings: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(JSONBlob.encode(self))
    }
}

extension StampInput: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(projectTitle)
        hasher.combine(shortCaption)
        hasher.combine(isImported)
        hasher.combine(dateInfo.local?.iso)
        hasher.combine(location.flatMap { JSONBlob.encode($0) })
    }
}

/// Neutral drawn sample used where no real photo is shown.
enum SampleImage {
    private static var cached: CGImage?

    static func make() -> CGImage {
        if let cached { return cached }
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.78, green: 0.83, blue: 0.88, alpha: 1).cgColor, UIColor(red: 0.50, green: 0.56, blue: 0.64, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(red: 0.35, green: 0.39, blue: 0.46, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: size.height * 0.68, width: size.width, height: size.height * 0.32))
            UIColor.white.withAlphaComponent(0.6).setFill()
            cg.fill(CGRect(x: 160, y: size.height * 0.68 - 160, width: 260, height: 160))
            cg.fill(CGRect(x: 480, y: size.height * 0.68 - 120, width: 320, height: 120))
        }
        let result = image.cgImage!
        cached = result
        return result
    }
}

/// Default stamp for new photos (Settings and camera). Existing photos keep their own snapshot.
struct DefaultStampSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var settings = StampSettings.default
    @State private var loaded = false
    var showsDoneButton = true

    var body: some View {
        NavigationStack {
            Form {
                StampSettingsEditor(settings: $settings, previewInput: sampleInput)
                Section {
                    Text(L("stamp.default.footer")).font(.footnote).foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle(L("stamp.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) { Button(L("common.done")) { dismiss() } }
                }
            }
        }
        .onAppear {
            guard !loaded, let repository = env.repository else { return }
            settings = repository.preferences().defaultStamp
            loaded = true
        }
        .onChange(of: settings) { _, value in
            guard loaded, let repository = env.repository else { return }
            repository.preferences().defaultStamp = value
            try? repository.save()
        }
    }

    private var sampleInput: StampInput {
        let now = Date()
        let offset = TimeZone.current.secondsFromGMT(for: now)
        var location = PhotoLocation(source: .device)
        location.latitude = 40.71280
        location.longitude = -74.00600
        location.horizontalAccuracy = 12
        location.accuracyAuthorization = .full
        location.addressOriginal = L("stamp.sample.address")
        return StampInput(dateInfo: PhotoDateInfo(kind: .device, local: LocalDateTime(date: now, offsetSeconds: offset), offsetSeconds: offset),
                          isImported: false, projectTitle: L("stamp.sample.project"), location: location,
                          shortCaption: L("stamp.sample.caption"))
    }
}
