import XCTest
@testable import TimestampCameraWorkPhotos

final class PriceMathTests: XCTestCase {
    func testYearlySavingsRoundsDown() {
        // $4.99 × 12 = $59.88; $29.99 is 49.92 % cheaper → 49 %, never 50 %.
        XCTAssertEqual(PriceMath.yearlySavingsPercent(monthly: Decimal(string: "4.99")!, yearly: Decimal(string: "29.99")!), 49)
        XCTAssertEqual(PriceMath.yearlySavingsPercent(monthly: Decimal(string: "10")!, yearly: Decimal(string: "60")!), 50)
        XCTAssertEqual(PriceMath.yearlySavingsPercent(monthly: Decimal(string: "9.99")!, yearly: Decimal(string: "59.99")!), 49)
        XCTAssertNil(PriceMath.yearlySavingsPercent(monthly: Decimal(string: "5")!, yearly: Decimal(string: "60")!))
        XCTAssertNil(PriceMath.yearlySavingsPercent(monthly: 0, yearly: Decimal(string: "29.99")!))
    }
}

final class AccessPolicyTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testFreeSingleProjectIsEditable() {
        let policy = AccessPolicy(isPro: false, projects: [.init(id: a, photoCount: 2, isArchived: false)], selectedFreeProjectID: nil,
                                  usage: FreeUsage(photosAdded: 2, projectsCreated: 1))
        XCTAssertEqual(policy.freeEditableProjectID, a)
        XCTAssertEqual(policy.access(for: a), .editable)
        XCTAssertFalse(policy.canCreateProject)
        XCTAssertEqual(policy.remainingFreePhotos, 1)
        XCTAssertEqual(policy.remainingPhotoSlots(for: a), 1, "Limited by the lifetime quota of 3 photos")
        XCTAssertEqual(policy.remainingPhotoSlots(for: nil), 1, "Unsorted uses the same quota")
        XCTAssertEqual(policy.projectCapacity(for: a), 18)
        XCTAssertEqual(policy.reportPhotoLimit, 20)
        XCTAssertFalse(policy.canExport(template: .beforeAfter))
        XCTAssertTrue(policy.canExport(template: .standard))
    }

    /// Owner decision: 3 free photos for the whole life of the app; deleting them does not give them back.
    func testFreePhotoQuotaIsLifetime() {
        let policy = AccessPolicy(isPro: false, projects: [.init(id: a, photoCount: 0, isArchived: false)], selectedFreeProjectID: a,
                                  usage: FreeUsage(photosAdded: 3, projectsCreated: 1))
        XCTAssertTrue(policy.isFreePhotoQuotaUsedUp)
        XCTAssertEqual(policy.remainingPhotoSlots(for: a), 0)
        XCTAssertEqual(policy.remainingPhotoSlots(for: nil), 0)
        XCTAssertEqual(policy.shownRemainingPhotoSlots(for: nil), 0)
        XCTAssertEqual(policy.projectCapacity(for: a), 20, "Existing photos can still be moved in")
        XCTAssertEqual(policy.reportPhotoLimit, 20, "Reports from existing photos stay free")
    }

    func testFreeFullProjectHasNoSlots() {
        let policy = AccessPolicy(isPro: false, projects: [.init(id: a, photoCount: 20, isArchived: false)], selectedFreeProjectID: a)
        XCTAssertEqual(policy.access(for: a), .editable)
        XCTAssertEqual(policy.remainingPhotoSlots(for: a), 0)
    }

    /// Owner decision (replaces A30's "archive and start a new one"): one project in total —
    /// archiving or deleting it does not allow a new one in Free.
    func testArchivingOrDeletingDoesNotFreeTheProjectSlot() {
        let used = FreeUsage(photosAdded: 3, projectsCreated: 1)
        let archived = AccessPolicy(isPro: false, projects: [.init(id: a, photoCount: 3, isArchived: true)], selectedFreeProjectID: a, usage: used)
        XCTAssertNil(archived.freeEditableProjectID)
        XCTAssertEqual(archived.access(for: a), .archived)
        XCTAssertFalse(archived.canCreateProject)
        let deleted = AccessPolicy(isPro: false, projects: [], selectedFreeProjectID: nil, usage: used)
        XCTAssertFalse(deleted.canCreateProject)
        let fresh = AccessPolicy(isPro: false, projects: [], selectedFreeProjectID: nil, usage: FreeUsage())
        XCTAssertTrue(fresh.canCreateProject, "The first project is free")
        XCTAssertTrue(AccessPolicy(isPro: true, projects: [], selectedFreeProjectID: nil, usage: used).canCreateProject)
    }

    /// A22 / PAY-05: after Pro ends, nothing is cut — a 100-photo project is read-only but complete.
    func testExpiredProWithManyProjects() {
        let projects: [AccessPolicy.ProjectUsage] = [
            .init(id: a, photoCount: 100, isArchived: false),
            .init(id: b, photoCount: 12, isArchived: false),
            .init(id: c, photoCount: 3, isArchived: false)
        ]
        let usage = FreeUsage(photosAdded: 115, projectsCreated: 3)
        let policy = AccessPolicy(isPro: false, projects: projects, selectedFreeProjectID: nil, usage: usage)
        XCTAssertNil(policy.freeEditableProjectID, "With several active projects the user chooses explicitly")
        XCTAssertEqual(policy.access(for: a), .readOnlyTooManyPhotos)
        XCTAssertEqual(policy.access(for: b), .readOnlyNotSelected)
        XCTAssertFalse(policy.canCreateProject, "The Free project quota is used")
        XCTAssertFalse(policy.canSelectAsFreeProject(a), "More than 20 photos cannot become the Free project")
        XCTAssertTrue(policy.canSelectAsFreeProject(b))

        let chosen = AccessPolicy(isPro: false, projects: projects, selectedFreeProjectID: b, usage: usage)
        XCTAssertEqual(chosen.access(for: b), .editable)
        XCTAssertEqual(chosen.access(for: c), .readOnlyNotSelected)
        XCTAssertFalse(chosen.canCreateProject)
        XCTAssertEqual(chosen.remainingPhotoSlots(for: b), 0, "No new photos: the Free photo quota is used")
        XCTAssertEqual(chosen.projectCapacity(for: b), 8)
        XCTAssertEqual(chosen.remainingPhotoSlots(for: c), 0)
    }

    func testSelectedProjectOverLimitIsNotEditable() {
        let policy = AccessPolicy(isPro: false, projects: [.init(id: a, photoCount: 25, isArchived: false)], selectedFreeProjectID: a,
                                  usage: FreeUsage(photosAdded: 25, projectsCreated: 1))
        XCTAssertEqual(policy.access(for: a), .readOnlyTooManyPhotos)
        XCTAssertFalse(policy.canCreateProject)
    }

    func testProUnlocksEverything() {
        let projects: [AccessPolicy.ProjectUsage] = [.init(id: a, photoCount: 999, isArchived: false), .init(id: b, photoCount: 1000, isArchived: false)]
        let policy = AccessPolicy(isPro: true, projects: projects, selectedFreeProjectID: nil, usage: FreeUsage(photosAdded: 1999, projectsCreated: 2))
        XCTAssertEqual(policy.access(for: a), .editable)
        XCTAssertEqual(policy.remainingPhotoSlots(for: a), 1)
        XCTAssertEqual(policy.remainingPhotoSlots(for: b), 0)
        XCTAssertFalse(policy.isFreePhotoQuotaUsedUp)
        XCTAssertNil(policy.shownRemainingPhotoSlots(for: nil), "Unsorted has no limit to show with Pro")
        XCTAssertTrue(policy.canCreateProject)
        XCTAssertEqual(policy.reportPhotoLimit, 200)
        XCTAssertTrue(policy.canBatchExport)
        XCTAssertNil(policy.stampedExportMaxPixel)
    }

    @MainActor
    func testRepositoryPersistsAutomaticFreeSelection() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var draft = ProjectDraft()
        draft.title = "One"
        let project = try env.repository.createProject(draft, makeFreeProject: false)
        XCTAssertNil(env.repository.preferences().selectedFreeProjectID)
        env.repository.persistFreeSelectionIfNeeded(isPro: false)
        XCTAssertEqual(env.repository.preferences().selectedFreeProjectID, project.id)
    }

    /// The quota counts every created project and added photo and never goes down.
    @MainActor
    func testUsageLedgerCountsForeverAndReconcilesUpward() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var draft = ProjectDraft()
        draft.title = "One"
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        XCTAssertEqual(env.repository.usage.usage.projectsCreated, 1)
        XCTAssertFalse(env.repository.accessPolicy(isPro: false).canCreateProject)
        try env.repository.deleteProject(project)
        XCTAssertFalse(env.repository.accessPolicy(isPro: false).canCreateProject, "Deleting does not free the slot")
        XCTAssertTrue(env.repository.accessPolicy(isPro: true).canCreateProject)

        env.repository.usage.recordPhotosAdded(3)
        XCTAssertTrue(env.repository.accessPolicy(isPro: false).isFreePhotoQuotaUsedUp)
        env.repository.reconcileUsage()
        XCTAssertEqual(env.repository.usage.usage, FreeUsage(photosAdded: 3, projectsCreated: 1), "Reconcile never lowers")
        for _ in 0..<5 { _ = try env.addPhoto(projectID: nil) }
        env.repository.reconcileUsage()
        XCTAssertEqual(env.repository.usage.usage.photosAdded, 5, "Photos already on the device (e.g. restored) count")
    }

    @MainActor
    func testUsageSurvivesANewLedgerAndKeychainRoundTrip() {
        let store = MemoryUsageStore()
        let first = UsageLedger(store: store)
        first.recordProjectCreated()
        first.recordPhotosAdded(2)
        XCTAssertEqual(UsageLedger(store: store).usage, FreeUsage(photosAdded: 2, projectsCreated: 1))

        // The real Keychain item of the app (restored afterwards).
        let keychain = KeychainUsageStore()
        let original = keychain.load()
        defer { if let original { keychain.save(original) } else { keychain.clear() } }
        keychain.save(FreeUsage(photosAdded: 7, projectsCreated: 2))
        XCTAssertEqual(keychain.load(), FreeUsage(photosAdded: 7, projectsCreated: 2))
        keychain.save(FreeUsage(photosAdded: 8, projectsCreated: 2))
        XCTAssertEqual(keychain.load(), FreeUsage(photosAdded: 8, projectsCreated: 2), "Updates the existing item")
    }
}

final class StampTests: XCTestCase {
    private func lines(count: Int = 2) -> [StampLine] {
        (0..<count).map { StampLine(text: "Line \($0) 8 Oct 2026, 14:03 UTC+02:00", style: $0 == 0 ? .primary : .secondary) }
    }

    func testSafeMarginOnEveryAspectRatioAndCorner() throws {
        let sizes = [CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032), CGSize(width: 1080, height: 1080),
                     CGSize(width: 8000, height: 1500), CGSize(width: 600, height: 4000)]
        for size in sizes {
            for position in StampPosition.allCases {
                var settings = StampSettings.default
                settings.position = position
                let layout = try XCTUnwrap(StampRenderer.layout(lines: lines(), settings: settings, imageSize: size))
                let margin = min(size.width, size.height) * 0.03
                let box = layout.boxRect
                XCTAssertGreaterThanOrEqual(box.minX, margin - 0.5, "\(size) \(position)")
                XCTAssertGreaterThanOrEqual(box.minY, margin - 0.5, "\(size) \(position)")
                XCTAssertLessThanOrEqual(box.maxX, size.width - margin + 0.5, "\(size) \(position)")
                XCTAssertLessThanOrEqual(box.maxY, size.height - margin + 0.5, "\(size) \(position)")
                XCTAssertEqual(position.isLeft, box.midX < size.width / 2, "\(size) \(position)")
                XCTAssertEqual(position.isTop, box.midY < size.height / 2, "\(size) \(position)")
            }
        }
    }

    /// The same stamp looks the same on a preview and on the full-size file (normalized geometry).
    func testLayoutScalesWithImageSize() throws {
        let small = try XCTUnwrap(StampRenderer.layout(lines: lines(), settings: .default, imageSize: CGSize(width: 1008, height: 756)))
        let large = try XCTUnwrap(StampRenderer.layout(lines: lines(), settings: .default, imageSize: CGSize(width: 4032, height: 3024)))
        let a = small.normalizedBox
        let b = large.normalizedBox
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.01)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.01)
        XCTAssertEqual(a.width, b.width, accuracy: 0.01)
        XCTAssertEqual(a.height, b.height, accuracy: 0.01)
    }

    func testLongTextWrapsInsteadOfBeingCut() throws {
        let size = CGSize(width: 4032, height: 3024)
        let long = String(repeating: "Hauptstraße 123, Wohnung 45, Hinterhaus ", count: 4)
        let single = try XCTUnwrap(StampRenderer.layout(lines: [StampLine(text: "Hauptstraße", style: .secondary)], settings: .default, imageSize: size))
        let layout = try XCTUnwrap(StampRenderer.layout(lines: [StampLine(text: long, style: .secondary)], settings: .default, imageSize: size))
        XCTAssertLessThanOrEqual(layout.boxRect.width, size.width - 2 * layout.margin + 1)
        XCTAssertGreaterThan(layout.lines[0].rect.height, single.lines[0].rect.height * 1.8, "Wrapped onto several lines")
        // Every character is still in the layout (nothing cut).
        XCTAssertEqual(layout.lines[0].attributed.string, long)
        XCTAssertEqual(TextBox.fittingLength(layout.lines[0].attributed, width: layout.lines[0].rect.width,
                                             height: layout.lines[0].rect.height), (long as NSString).length)
        XCTAssertFalse(layout.overflow)
    }

    func testOverflowIsReportedNotCut() throws {
        var settings = StampSettings.default
        settings.size = .large
        let many = (0..<30).map { StampLine(text: "Row \($0) with some text", style: .secondary) }
        let layout = try XCTUnwrap(StampRenderer.layout(lines: many, settings: settings, imageSize: CGSize(width: 1000, height: 400)))
        XCTAssertTrue(layout.overflow)
        let image = TestImages.image(width: 1000, height: 400)
        XCTAssertThrowsError(try StampRenderer.render(image: image, lines: many, settings: settings))
    }

    func testNoFieldsMeansNoStamp() {
        var settings = StampSettings.default
        settings.fields = StampFields(dateTime: false, projectName: false, address: false, coordinates: false, caption: false)
        let input = StampInput(dateInfo: PhotoDateInfo(kind: .device, local: LocalDateTime(iso: "2026-10-08T14:03:00"), offsetSeconds: 7200),
                               isImported: false, projectTitle: "P", location: nil, shortCaption: "")
        XCTAssertTrue(StampContentBuilder.lines(input: input, settings: settings, language: .en, includeLocation: true).isEmpty)
    }

    /// STAMP-01: manual/imported/time zone/approximate marks are always shown with the related field.
    func testProvenanceLabels() {
        var settings = StampSettings.default
        settings.fields = StampFields(dateTime: true, projectName: true, address: true, coordinates: true, caption: true)
        var location = PhotoLocation(source: .device)
        location.latitude = 52.5
        location.longitude = 13.4
        location.horizontalAccuracy = 1500
        location.accuracyAuthorization = .reduced
        location.addressOriginal = "Berlin, Germany"
        let manual = StampInput(dateInfo: PhotoDateInfo(kind: .manual, local: LocalDateTime(iso: "2026-10-08T14:03:00"), offsetSeconds: 7200),
                                isImported: true, projectTitle: "Apartment 24", location: location, shortCaption: "Kitchen")
        let text = StampContentBuilder.lines(input: manual, settings: settings, language: .en, includeLocation: true).map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Manual date"), text)
        XCTAssertTrue(text.contains("Imported"), text)
        XCTAssertTrue(text.contains("≈ Berlin, Germany"), text)
        XCTAssertTrue(text.contains("Approximate"), text)
        XCTAssertTrue(text.contains("Apartment 24"), text)
        XCTAssertTrue(text.contains("Kitchen"), text)

        let noZone = StampInput(dateInfo: PhotoDateInfo(kind: .importedNoOffset, local: LocalDateTime(iso: "2026-10-08T14:03:00"), offsetSeconds: nil),
                                isImported: true, projectTitle: nil, location: nil, shortCaption: "")
        let noZoneText = StampContentBuilder.lines(input: noZone, settings: settings, language: .en, includeLocation: true).map(\.text).joined()
        XCTAssertTrue(noZoneText.contains("Time zone unknown"), noZoneText)
        XCTAssertFalse(noZoneText.contains("UTC"), "No invented offset")

        let noDate = StampInput(dateInfo: PhotoDateInfo(kind: .unavailable, local: nil, offsetSeconds: nil),
                                isImported: true, projectTitle: nil, location: nil, shortCaption: "")
        XCTAssertTrue(StampContentBuilder.lines(input: noDate, settings: settings, language: .en, includeLocation: true)
            .contains { $0.text == "Capture time unavailable" })
    }

    /// A10: "Without location" removes address and coordinates from the stamp.
    func testWithoutLocationRemovesPlaceFromStamp() {
        var settings = StampSettings.default
        settings.fields = StampFields(dateTime: true, projectName: false, address: true, coordinates: true, caption: false)
        var location = PhotoLocation(source: .device)
        location.latitude = 40.7128
        location.longitude = -74.006
        location.horizontalAccuracy = 10
        location.addressOriginal = "1 Main St"
        let input = StampInput(dateInfo: PhotoDateInfo(kind: .device, local: LocalDateTime(iso: "2026-10-08T14:03:00"), offsetSeconds: 0),
                               isImported: false, projectTitle: nil, location: location, shortCaption: "")
        let with = StampContentBuilder.lines(input: input, settings: settings, language: .en, includeLocation: true).map(\.text).joined()
        let without = StampContentBuilder.lines(input: input, settings: settings, language: .en, includeLocation: false).map(\.text).joined()
        XCTAssertTrue(with.contains("1 Main St"))
        XCTAssertTrue(with.contains("40.71280° N"))
        XCTAssertFalse(without.contains("1 Main St"))
        XCTAssertFalse(without.contains("40.71280"))
    }

    /// A04: an approximate position is shown and printed only with its real precision.
    func testApproximateCoordinatesHaveNoFalsePrecision() {
        var location = PhotoLocation(source: .device)
        location.latitude = 40.712776
        location.longitude = -74.005974
        location.horizontalAccuracy = 1500
        location.accuracyAuthorization = .reduced
        let line = StampContentBuilder.coordinateLine(location, strings: LocalizedStrings(language: .en))
        XCTAssertTrue(line.hasPrefix("40.71° N, 74.01° W"), line)
        XCTAssertTrue(line.contains("Approximate"), line)
        location.horizontalAccuracy = 300
        location.accuracyAuthorization = .full
        XCTAssertEqual(CoordinateFormatting.string(location), "40.713° N, 74.006° W")
        location.horizontalAccuracy = 8
        XCTAssertEqual(CoordinateFormatting.string(location), "40.71278° N, 74.00597° W")
    }

    func testManualLocationIsMarkedAndCreatesNoCoordinates() {
        var location = PhotoLocation(source: .manual)
        location.addressOverride = "Site office"
        location.addressOverrideKind = .manual
        XCTAssertFalse(location.hasCoordinates)
        let line = StampContentBuilder.addressLine("Site office", location: location, strings: LocalizedStrings(language: .en))
        XCTAssertEqual(line, "Site office · Manual location")
        location.addressOverrideKind = .project
        XCTAssertTrue(StampContentBuilder.addressLine("Site", location: location, strings: LocalizedStrings(language: .en)).contains("Project address"))
    }

    func testShortCaptionIsVisiblyShortened() {
        let caption = String(repeating: "word ", count: 60)
        let short = StampText.shortened(caption, limit: 120)
        XCTAssertLessThanOrEqual(short.count, 120)
        XCTAssertTrue(short.hasSuffix("…"))
        XCTAssertEqual(StampText.shortened("Short", limit: 120), "Short")
    }

    func testPresetMatching() {
        XCTAssertEqual(StampPreset.matching(StampPreset.compact.fields!), .compact)
        XCTAssertEqual(StampPreset.matching(StampPreset.work.fields!), .work)
        XCTAssertEqual(StampPreset.matching(StampPreset.location.fields!), .location)
        XCTAssertEqual(StampPreset.matching(StampFields(dateTime: false, projectName: true, address: false, coordinates: true, caption: false)), .custom)
        XCTAssertEqual(StampSettings.default.preset, .compact, "By default only the date and time")
    }

    /// A11: editing the stamp never changes the original file.
    @MainActor
    func testStampChangesKeepOriginalHash() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let photo = try env.addPhoto(projectID: nil)
        let url = try env.files.url(forRelative: photo.originalPath)
        let before = try FileStore.sha256(of: url)
        for size in [StampSize.small, .large, .medium] {
            var settings = StampSettings.default
            settings.size = size
            settings.fields.projectName = size == .large
            try env.repository.updateStamp(photo, settings: settings)
        }
        try env.repository.updateCaption(photo, caption: "New caption", shortCaption: "Short")
        try env.repository.applyStamp(.default, to: [photo])
        XCTAssertEqual(try FileStore.sha256(of: url), before)
        XCTAssertEqual(photo.sha256, before)
    }
}
