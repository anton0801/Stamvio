import Foundation

/// Free / Pro rules (PAY-01, PAY-05 with the owner's changes in Docs/TZ-Changelog.md).
/// Pure value logic so it can be unit-tested.
///
/// - Free: 3 photos and 1 project for the whole life of the app (captured or imported, in a
///   project or Unsorted). Deleting or archiving does not give the quota back; a new project
///   after the first one needs Pro. The editable project (≤ 20 photos) is identified only by
///   `AppPreferences.selectedFreeProjectID`; other projects are read-only but fully viewable
///   and exportable.
/// - Pro: any number of projects, up to 1 000 photos per project.
/// - Data is never hidden or deleted because of the subscription state.
struct AccessPolicy: Equatable {
    /// New photos the Free plan allows in total (lifetime, deletions do not count back).
    static let freeLifetimePhotoLimit = 3
    /// Projects the Free plan allows to create in total (lifetime).
    static let freeLifetimeProjectLimit = 1
    /// Size of the editable Free project (e.g. a project kept after Pro ended).
    static let freePhotoLimit = 20
    static let proPhotoLimit = 1000
    static let freeReportPhotoLimit = 20
    static let proReportPhotoLimit = 200
    static let proReportPairLimit = 100
    static let importBatchLimit = 50
    static let brandPresetLimit = 10
    /// Long side of stamped JPEG exports in Free (Pro can export at original resolution).
    static let freeExportMaxPixel = 2560

    struct ProjectUsage: Equatable {
        let id: UUID
        let photoCount: Int
        let isArchived: Bool
    }

    enum ProjectAccess: Equatable {
        case editable
        /// Free: another project is the Free project.
        case readOnlyNotSelected
        /// Free: more than 20 photos (e.g. after Pro ended). Nothing is cut or hidden.
        case readOnlyTooManyPhotos
        case archived

        var canEdit: Bool { self == .editable }
    }

    let isPro: Bool
    let projects: [ProjectUsage]
    let selectedFreeProjectID: UUID?
    var usage = FreeUsage()
    var photoQuota = AccessPolicy.freeLifetimePhotoLimit

    var activeProjects: [ProjectUsage] { projects.filter { !$0.isArchived } }

    /// The only editable project in Free, or nil if none qualifies.
    var freeEditableProjectID: UUID? {
        let active = activeProjects
        if let selected = selectedFreeProjectID, let project = active.first(where: { $0.id == selected }) {
            return project.photoCount <= Self.freePhotoLimit ? project.id : nil
        }
        // No valid selection: a single active project that fits the limit becomes the Free project.
        if active.count == 1, let only = active.first, only.photoCount <= Self.freePhotoLimit {
            return only.id
        }
        return nil
    }

    /// Free selection that should be persisted (auto-selection of the single fitting project).
    var resolvedFreeSelection: UUID? {
        guard !isPro else { return selectedFreeProjectID }
        return freeEditableProjectID ?? selectedFreeProjectID
    }

    func access(for projectID: UUID) -> ProjectAccess {
        guard let project = projects.first(where: { $0.id == projectID }) else { return .readOnlyNotSelected }
        if project.isArchived { return .archived }
        if isPro { return .editable }
        if freeEditableProjectID == projectID { return .editable }
        return project.photoCount > Self.freePhotoLimit ? .readOnlyTooManyPhotos : .readOnlyNotSelected
    }

    /// Free allows one project in total: deleting or archiving it does not allow a new one.
    var canCreateProject: Bool {
        isPro || (usage.projectsCreated < Self.freeLifetimeProjectLimit && freeEditableProjectID == nil)
    }

    /// New photos still allowed by the Free quota (unlimited with Pro).
    var remainingFreePhotos: Int {
        isPro ? Int.max : max(0, photoQuota - usage.photosAdded)
    }

    /// Free quota used up: the next capture or import opens the paywall.
    var isFreePhotoQuotaUsedUp: Bool { remainingFreePhotos == 0 }

    func photoLimit(for projectID: UUID) -> Int {
        isPro ? Self.proPhotoLimit : Self.freePhotoLimit
    }

    /// Room in the project for photos (also for moving existing photos in; 0 when read-only,
    /// archived or full). Does not look at the Free quota of new photos.
    func projectCapacity(for projectID: UUID) -> Int {
        guard access(for: projectID) == .editable,
              let project = projects.first(where: { $0.id == projectID }) else { return 0 }
        return max(0, photoLimit(for: projectID) - project.photoCount)
    }

    /// How many new photos (capture or import) can still go to the project, or to Unsorted for nil.
    func remainingPhotoSlots(for projectID: UUID?) -> Int {
        guard let projectID else { return remainingFreePhotos }
        return min(projectCapacity(for: projectID), remainingFreePhotos)
    }

    /// Same as `remainingPhotoSlots`, nil when there is no limit to show (Pro, Unsorted).
    func shownRemainingPhotoSlots(for projectID: UUID?) -> Int? {
        let remaining = remainingPhotoSlots(for: projectID)
        return remaining == Int.max ? nil : remaining
    }

    /// Whether the user can make this project the Free project (Free only, active, ≤ 20 photos).
    func canSelectAsFreeProject(_ projectID: UUID) -> Bool {
        guard !isPro, let project = projects.first(where: { $0.id == projectID }), !project.isArchived else { return false }
        return project.photoCount <= Self.freePhotoLimit && freeEditableProjectID != projectID
    }

    var reportPhotoLimit: Int { isPro ? Self.proReportPhotoLimit : Self.freeReportPhotoLimit }
    var reportPairLimit: Int { isPro ? Self.proReportPairLimit : 0 }

    func canExport(template: ReportTemplate) -> Bool { !template.requiresPro || isPro }

    var canBatchExport: Bool { isPro }
    var canUseBranding: Bool { isPro }
    var stampedExportMaxPixel: Int? { isPro ? nil : Self.freeExportMaxPixel }
}

/// What made the paywall appear; drives the headline benefit (PAY-03).
enum PaywallTrigger: String, Identifiable {
    case secondProject
    /// The Free quota of new photos is used up.
    case freePhotos
    /// The project is full (20 in Free for a kept project, 1 000 with Pro).
    case photoLimit
    case beforeAfterExport
    case branding
    case batchExport
    case brandPresets
    case originalResolution
    case reportLimit
    case settings

    var id: String { rawValue }

    var titleKey: String { "paywall.trigger.\(rawValue).title" }
    var messageKey: String { "paywall.trigger.\(rawValue).message" }
}

/// Price math for the paywall, using StoreKit prices of the same currency.
enum PriceMath {
    /// Savings of the yearly plan against 12 monthly payments, rounded **down** to a whole percent.
    /// $4.99/month vs $29.99/year → 49 % (49.9 %, never shown as 50 %).
    static func yearlySavingsPercent(monthly: Decimal, yearly: Decimal) -> Int? {
        guard monthly > 0, yearly > 0 else { return nil }
        let twelveMonths = monthly * 12
        guard yearly < twelveMonths else { return nil }
        var ratio = (twelveMonths - yearly) / twelveMonths * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &ratio, 0, .down)
        let value = NSDecimalNumber(decimal: rounded).intValue
        return value > 0 ? value : nil
    }
}
