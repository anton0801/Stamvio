import Foundation
import Observation
import SwiftData
import SwiftUI

/// Navigation shared between tabs (e.g. "Take photos" in a project opens the camera for it).
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case camera
        case projects
        case settings
    }

    var tab: Tab = .camera
    var projectsPath: [ProjectsRoute] = []

    func openCamera() {
        tab = .camera
    }

    func openProject(_ id: UUID) {
        tab = .projects
        projectsPath = [.project(id)]
    }
}

enum ProjectsRoute: Hashable {
    case project(UUID)
    case unsorted
    case photo(UUID)
    case report(UUID)
}

/// Composition root. Views receive it through the environment; services stay separate so views never
/// manage file paths, purchase transactions and the capture session at the same time.
@MainActor
@Observable
final class AppEnvironment {
    let files: FileStore
    let container: ModelContainer?
    let repository: ProjectRepository?
    let entitlements: EntitlementService
    let location: LocationService
    let geocoder: ReverseGeocodingService
    let analytics: LocalAnalyticsService
    let thumbnails: ThumbnailStore
    let capture: CaptureCoordinator?
    let router = AppRouter()
    let config: EnvironmentConfig
    private(set) var startupError: AppError?

    init(files: FileStore = .live(), inMemory: Bool = false, config: EnvironmentConfig = .current) {
        self.files = files
        self.config = config
        entitlements = EntitlementService()
        location = LocationService()
        geocoder = ReverseGeocodingService()
        analytics = LocalAnalyticsService()
        thumbnails = ThumbnailStore(files: files)

        var container: ModelContainer?
        var openError: AppError?
        do {
            try files.prepareDirectories()
            let schema = Schema(versionedSchema: SchemaV1.self)
            // No CloudKit: the app has no own cloud sync in v1.
            let configuration = inMemory
                ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                : ModelConfiguration(schema: schema, url: files.databaseURL, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: [configuration])
        } catch {
            // The store is never deleted automatically; the user sees the error and can contact support.
            openError = AppError(.databaseOpenFailed)
        }
        self.container = container
        startupError = openError
        if let container {
            let repository = ProjectRepository(container: container, files: files, usage: UsageLedger())
            self.repository = repository
            capture = CaptureCoordinator(repository: repository, files: files, location: location,
                                         geocoder: geocoder, analytics: analytics)
            location.isEnabled = repository.preferences().locationEnabled
        } else {
            repository = nil
            capture = nil
        }
    }

    /// Finishes interrupted work and starts the StoreKit listener.
    func launch() {
        entitlements.start()
        if let repository {
            Reconciler.run(repository: repository)
            repository.reconcileUsage()
        }
    }

    /// Free/Pro rules for the current data. Reading `revision` keeps SwiftUI views up to date.
    func policy() -> AccessPolicy {
        guard let repository else { return AccessPolicy(isPro: entitlements.isPro, projects: [], selectedFreeProjectID: nil) }
        _ = repository.revision
        return repository.accessPolicy(isPro: entitlements.isPro)
    }

    func persistFreeSelection() {
        repository?.persistFreeSelectionIfNeeded(isPro: entitlements.isPro)
    }

    /// "Delete all local data": database, files, caches, address cache and diagnostics.
    /// The subscription is not affected (managed by Apple).
    func deleteAllData() async throws {
        guard let repository else { return }
        try repository.deleteAllRecords()
        files.deleteAllUserFiles()
        thumbnails.clearMemory()
        await geocoder.clearCache()
        ErrorLog.shared.clear()
        location.isEnabled = false
        _ = repository.preferences()
    }
}
