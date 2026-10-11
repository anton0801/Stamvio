#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Debug-only launch arguments for UI tests and screenshots. Compiled out of Release builds,
/// so production never contains demo photos, fake GPS or fake entitlements.
///
/// - `-uitest-reset`: start from an empty state (data and onboarding).
/// - `-uitest-skip-onboarding`: mark onboarding as done.
/// - `-uitest-seed`: add a clearly labelled sample project with generated images.
/// - `-uitest-showcase`: with `-uitest-seed`, use plain demo names instead of "Sample" labels
///   (App Store preview footage, where the drawn rooms already read as illustrations).
@MainActor
enum DebugSeeding {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func apply(to env: AppEnvironment) {
        guard let repository = env.repository else { return }
        if arguments.contains("-uitest-reset") {
            try? repository.deleteAllRecords()
            env.files.deleteAllUserFiles()
            UserDefaults.standard.removeObject(forKey: "onboarding.completed")
            UserDefaults.standard.removeObject(forKey: "import.limitsSeen")
            UserDefaults.standard.removeObject(forKey: InterfaceLanguage.defaultsKey)
            repository.usage.resetForUITests()
        }
        if arguments.contains("-uitest-skip-onboarding") {
            UserDefaults.standard.set(true, forKey: "onboarding.completed")
        }
        if let index = arguments.firstIndex(of: "-uitest-free-photo-quota"), arguments.indices.contains(index + 1),
           let quota = Int(arguments[index + 1]) {
            repository.usage.debugPhotoQuota = quota
        }
        if arguments.contains("-uitest-pro-preview") {
            env.entitlements.debugProPreview = true
            Task { await env.entitlements.refreshEntitlements() }
        }
        if arguments.contains("-uitest-seed"), repository.allProjects().isEmpty {
            seed(repository: repository, files: env.files)
        }
        repository.reconcileUsage()
    }

    private static func seed(repository: ProjectRepository, files: FileStore) {
        let showcase = arguments.contains("-uitest-showcase")
        var draft = ProjectDraft()
        draft.title = showcase ? "Apartment 24 — Deep Clean" : "Apartment 24 — Cleaning (Sample)"
        draft.siteAddress = showcase ? "24 Linden Street" : "24 Sample Street"
        draft.clientName = showcase ? "M. Novak" : "Sample Client"
        draft.workDate = Date()
        guard let project = try? repository.createProject(draft, makeFreeProject: true) else { return }
        let prefs = repository.preferences()
        prefs.executorName = showcase ? "Clearline Cleaning" : "Sample Cleaning Co."
        prefs.executorContact = "+1 555 0100"
        try? repository.save()

        // Drawn sample rooms (marked as samples in the project title), before and after cleaning.
        let scenes: [(SampleScene.Kind, Bool)] = [(.kitchen, false), (.kitchen, true), (.bathroom, false), (.bathroom, true),
                                                  (.livingRoom, true), (.balcony, true)]
        let captions = ["Kitchen before cleaning", "Kitchen completed", "Bathroom before", "Bathroom completed",
                        "Living room", "Balcony windows"]
        var ids: [UUID] = []
        let now = Date()
        for (index, scene) in scenes.enumerated() {
            guard let data = sceneJPEG(scene.0, clean: scene.1) else { continue }
            let id = UUID()
            let path = FileStore.originalRelativePath(photoID: id, format: .jpeg)
            guard (try? files.writeAtomically(data, toRelative: path)) != nil,
                  let inspection = try? ImageInspector.inspect(data: data) else { continue }
            let shutter = now.addingTimeInterval(TimeInterval(-3600 + index * 300))
            let isImport = index == 4
            let record = PhotoRecord(id: id, projectID: project.id, source: isImport ? .import : .capture, originalPath: path,
                                     format: .jpeg, pixelWidth: inspection.pixelWidth, pixelHeight: inspection.pixelHeight,
                                     orientation: inspection.orientation, sha256: FileStore.sha256(of: data),
                                     byteSize: Int64(data.count), order: index, createdAt: shutter)
            if isImport {
                // Imported without capture date: shown as "Capture time unavailable".
                record.importedAt = now
                record.dateSourceRaw = DateSourceKind.unavailable.rawValue
            } else {
                let offset = TimeZone.current.secondsFromGMT(for: shutter)
                record.dateSourceRaw = DateSourceKind.device.rawValue
                record.captureInstant = shutter
                record.captureLocal = LocalDateTime(date: shutter, offsetSeconds: offset).iso
                record.captureOffsetSeconds = offset
                record.captureTimeZoneID = TimeZone.current.identifier
            }
            record.caption = captions[index]
            if index == 5 {
                var location = PhotoLocation(source: .manual)
                location.addressOverride = "Building B, 3rd floor"
                location.addressOverrideKind = .manual
                record.location = location
            }
            var stamp = StampSnapshot(settings: .default, language: .current)
            stamp.settings.fields = StampPreset.work.fields!
            record.stamp = stamp
            repository.refreshProvenance(record)
            try? repository.insert(record)
            ids.append(id)
        }
        if ids.count >= 4 {
            _ = try? repository.createPair(projectID: project.id, before: ids[0], after: ids[1], title: "Kitchen", caption: "Deep clean of all surfaces.")
            _ = try? repository.createPair(projectID: project.id, before: ids[2], after: ids[3], title: "Bathroom", caption: "")
        }
        if let data = sceneJPEG(.livingRoom, clean: false) {
            let id = UUID()
            let path = FileStore.originalRelativePath(photoID: id, format: .jpeg)
            if (try? files.writeAtomically(data, toRelative: path)) != nil, let inspection = try? ImageInspector.inspect(data: data) {
                let record = PhotoRecord(id: id, projectID: nil, source: .capture, originalPath: path, format: .jpeg,
                                         pixelWidth: inspection.pixelWidth, pixelHeight: inspection.pixelHeight, orientation: 1,
                                         sha256: FileStore.sha256(of: data), byteSize: Int64(data.count), order: 0)
                record.dateSourceRaw = DateSourceKind.device.rawValue
                record.captureInstant = now
                record.captureLocal = LocalDateTime(date: now, offsetSeconds: TimeZone.current.secondsFromGMT()).iso
                record.captureOffsetSeconds = TimeZone.current.secondsFromGMT()
                record.stamp = StampSnapshot(settings: .default, language: .current)
                try? repository.insert(record)
            }
        }
    }

    private static func sceneJPEG(_ kind: SampleScene.Kind, clean: Bool) -> Data? {
        let renderer = ImageRenderer(content: SampleScene(kind: kind, clean: clean).frame(width: 2000, height: 1500))
        renderer.scale = 1
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
    }
}
#endif
