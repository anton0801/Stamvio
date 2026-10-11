import Foundation
import os

/// Where an event happened (screen-level, no content).
enum AnalyticsSource: String {
    case camera
    case project
    case unsorted
    case photo
    case report
    case backup
    case settings
    case paywall
}

/// Minimal anonymous events (section 16). Parameters are typed so that names, addresses, GPS,
/// EXIF, captions, emails or any user text cannot be attached by mistake.
enum AnalyticsEvent: Equatable {
    case onboardingCompleted
    case projectCreated
    case captureSaved
    case importCompleted(photoCount: Int, failedCount: Int)
    case pairCompleted
    case reportPreviewed(template: ReportTemplate)
    case reportGenerated(template: ReportTemplate, photoCount: Int, duration: TimeInterval)
    case shareSheetOpened(source: AnalyticsSource)
    /// Positive callback of the system share flow only. Not proof of delivery or reading.
    case shareCompleted(source: AnalyticsSource)
    case paywallViewed(trigger: PaywallTrigger)
    case purchaseResult(result: String, errorCode: AppErrorCode?)
    case restoreResult(found: Bool, errorCode: AppErrorCode?)
    case backupCreated(photoCount: Int)
    case backupRestored(photoCount: Int)
    case supportOpened(source: AnalyticsSource)
    case error(code: AppErrorCode, source: AnalyticsSource)

    var name: String {
        switch self {
        case .onboardingCompleted: return "onboarding_completed"
        case .projectCreated: return "project_created"
        case .captureSaved: return "capture_saved"
        case .importCompleted: return "import_completed"
        case .pairCompleted: return "pair_completed"
        case .reportPreviewed: return "report_previewed"
        case .reportGenerated: return "report_generated"
        case .shareSheetOpened: return "share_sheet_opened"
        case .shareCompleted: return "share_completed"
        case .paywallViewed: return "paywall_viewed"
        case .purchaseResult: return "purchase_result"
        case .restoreResult: return "restore_result"
        case .backupCreated: return "backup_created"
        case .backupRestored: return "backup_restored"
        case .supportOpened: return "support_opened"
        case .error: return "error"
        }
    }

    /// Only allowed keys: source, templateType, photoCountRange, processingDurationBucket, errorCode, result.
    var parameters: [String: String] {
        switch self {
        case .onboardingCompleted, .projectCreated, .captureSaved, .pairCompleted:
            return [:]
        case let .importCompleted(photoCount, failedCount):
            return ["photoCountRange": Self.countBucket(photoCount), "failedRange": Self.countBucket(failedCount)]
        case let .reportPreviewed(template):
            return ["templateType": template.rawValue]
        case let .reportGenerated(template, photoCount, duration):
            return ["templateType": template.rawValue, "photoCountRange": Self.countBucket(photoCount),
                    "processingDurationBucket": Self.durationBucket(duration)]
        case let .shareSheetOpened(source), let .shareCompleted(source), let .supportOpened(source):
            return ["source": source.rawValue]
        case let .paywallViewed(trigger):
            return ["source": trigger.rawValue]
        case let .purchaseResult(result, errorCode):
            var parameters = ["result": result]
            if let errorCode { parameters["errorCode"] = errorCode.rawValue }
            return parameters
        case let .restoreResult(found, errorCode):
            var parameters = ["result": found ? "found" : "none"]
            if let errorCode { parameters["errorCode"] = errorCode.rawValue }
            return parameters
        case let .backupCreated(photoCount), let .backupRestored(photoCount):
            return ["photoCountRange": Self.countBucket(photoCount)]
        case let .error(code, source):
            return ["errorCode": code.rawValue, "source": source.rawValue]
        }
    }

    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1...5: return "1-5"
        case 6...20: return "6-20"
        case 21...50: return "21-50"
        case 51...200: return "51-200"
        default: return "200+"
        }
    }

    static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5: return "<5s"
        case 5..<15: return "5-15s"
        case 15..<60: return "15-60s"
        default: return "60s+"
        }
    }
}

protocol AnalyticsService: AnyObject {
    func track(_ event: AnalyticsEvent)
}

/// v1 adapter: nothing leaves the device. Collection is disabled until a provider is chosen and
/// configured explicitly (with privacy metadata). In Debug builds events are logged locally.
final class LocalAnalyticsService: AnalyticsService {
    private let logger = Logger(subsystem: "WorkPhotos", category: "analytics")
    private(set) var recentEvents: [AnalyticsEvent] = []
    /// No provider is configured in this version.
    let isCollectionConfigured = false

    func track(_ event: AnalyticsEvent) {
        #if DEBUG
        recentEvents.append(event)
        if recentEvents.count > 100 { recentEvents.removeFirst() }
        logger.debug("event \(event.name, privacy: .public) \(event.parameters.description, privacy: .public)")
        #endif
    }
}
