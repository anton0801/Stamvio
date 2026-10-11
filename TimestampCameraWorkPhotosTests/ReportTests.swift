import PDFKit
import XCTest
@testable import TimestampCameraWorkPhotos

final class ReportLayoutTests: XCTestCase {
    private func photo(_ index: Int, width: Int = 4032, height: Int = 3024, caption: String = "") -> ReportSnapshot.PhotoInfo {
        ReportSnapshot.PhotoInfo(id: UUID(), originalPath: "Originals/\(index).jpg", orientedWidth: width, orientedHeight: height,
                                 caption: caption, isImported: false,
                                 dateInfo: PhotoDateInfo(kind: .device, local: LocalDateTime(iso: "2026-10-08T14:03:00"), offsetSeconds: 7200),
                                 location: nil)
    }

    private func snapshot(photos: [ReportSnapshot.PhotoInfo], pairs: [ReportSnapshot.PairInfo] = [], template: ReportTemplate = .standard,
                          pageSize: PageSize = .a4, language: AppLanguage = .en, summary: String = "") -> ReportSnapshot {
        var settings = ReportSettings()
        settings.template = template
        settings.pageSize = pageSize
        settings.language = language
        settings.summary = summary
        settings.title = "Apartment 24 — Cleaning"
        return ReportSnapshot(reportID: UUID(), createdAt: Date(), createdOffsetSeconds: 7200, settings: settings,
                              project: .init(id: UUID(), title: "Apartment 24", siteAddress: "1 Main St", clientName: "Client", workDate: "2026-10-08"),
                              photos: photos, pairs: pairs, branding: .init(executorName: "Alex", contactText: "alex@site", logoPath: nil, showCreatedWith: true),
                              isProPreview: false, appName: "Stamvio")
    }

    private func photoRects(_ pages: [ReportPage]) -> [[(UUID, CGRect)]] {
        pages.map { page in page.elements.compactMap { if case let .photo(id, rect) = $0 { return (id, rect) } else { return nil } } }
    }

    func testMarginsAreAtLeast14mm() {
        let fourteenMM: CGFloat = 14 / 25.4 * 72
        XCTAssertGreaterThanOrEqual(ReportStyle.margin, fourteenMM)
        XCTAssertGreaterThanOrEqual(ReportStyle.technicalSize, 9)
        XCTAssertEqual(ReportStyle.bodySize, 11)
        XCTAssertEqual(PageSize.a4.pointSize.width, 595.2756, accuracy: 0.01)
        XCTAssertEqual(PageSize.letter.pointSize, CGSize(width: 612, height: 792))
    }

    func testStandardHasAtMostTwoPhotosPerPageAndAllPhotos() {
        for pageSize in PageSize.allCases {
            let photos = (0..<9).map { photo($0) }
            let engine = ReportLayoutEngine(snapshot: snapshot(photos: photos, pageSize: pageSize), logoAspect: nil)
            let pages = engine.makePages()
            let perPage = photoRects(pages)
            XCTAssertTrue(perPage.allSatisfy { $0.count <= 2 }, "\(pageSize)")
            XCTAssertEqual(Set(perPage.flatMap { $0.map(\.0) }), Set(photos.map(\.id)), "Every photo is in the report")
            XCTAssertFalse(perPage[0].isEmpty, "The first page has the title and photos — no empty cover")
            let content = ReportStyle(pageSize: pageSize.pointSize).contentRect
            for page in pages {
                for element in page.elements {
                    switch element {
                    case let .photo(_, rect), let .text(_, rect):
                        XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(rect), "\(rect) outside \(content)")
                    default: break
                    }
                }
            }
        }
    }

    func testTwoPhotoReportFitsOnOnePage() {
        let engine = ReportLayoutEngine(snapshot: snapshot(photos: [photo(0), photo(1)]), logoAspect: nil)
        let pages = engine.makePages()
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(photoRects(pages)[0].count, 2)
    }

    func testPhotosAreNeverCropped() {
        let photos = [photo(0, width: 3024, height: 4032), photo(1, width: 8000, height: 2000), photo(2, width: 1000, height: 1000)]
        let pages = ReportLayoutEngine(snapshot: snapshot(photos: photos), logoAspect: nil).makePages()
        for (id, rect) in photoRects(pages).flatMap({ $0 }) {
            let info = photos.first { $0.id == id }!
            XCTAssertEqual(rect.width / rect.height, info.aspectRatio, accuracy: 0.02, "Aspect ratio kept (fit, no crop)")
        }
    }

    /// A12: long captions in DE/FR/RU never shrink the text; they move to another page.
    func testLongCaptionsAreKeptWhole() {
        let captions = [
            String(repeating: "Gründliche Endreinigung der Küchenarbeitsplatte und Spülmaschinenverkleidung ", count: 6),
            String(repeating: "Nettoyage complet de la salle de bain, détartrage de la robinetterie ", count: 7),
            String(repeating: "Генеральная уборка кухни, мытьё фасадов и вытяжки ", count: 9)
        ].map { String($0.prefix(TextLimits.caption)) }
        for language in [AppLanguage.de, .fr, .ru] {
            let photos = (0..<6).map { photo($0, caption: captions[$0 % 3]) }
            let pages = ReportLayoutEngine(snapshot: snapshot(photos: photos, language: language), logoAspect: nil).makePages()
            let allText = pages.flatMap(\.elements).compactMap { element -> String? in
                if case let .text(string, _) = element { return string.string } else { return nil }
            }.joined(separator: "\n")
            for caption in captions {
                XCTAssertTrue(allText.contains(caption.trimmingCharacters(in: .whitespaces)), "Caption missing for \(language)")
            }
            XCTAssertTrue(photoRects(pages).allSatisfy { $0.count <= 2 })
            for page in pages {
                for element in page.elements {
                    if case let .text(string, rect) = element {
                        // The rect is tall enough for its text (nothing clipped).
                        XCTAssertGreaterThanOrEqual(rect.height + 1, TextBox.measure(string, width: rect.width).height)
                    }
                }
            }
        }
    }

    func testBeforeAfterOnePairPerPageAndMixedOrientation() {
        let before = photo(0, width: 3024, height: 4032)
        let after = photo(1, width: 4032, height: 3024)
        let second = (photo(2), photo(3))
        let pairs = [ReportSnapshot.PairInfo(id: UUID(), title: "Kitchen", caption: "Done", beforeID: before.id, afterID: after.id),
                     ReportSnapshot.PairInfo(id: UUID(), title: "Bath", caption: String(repeating: "Long note ", count: 60),
                                             beforeID: second.0.id, afterID: second.1.id)]
        let pages = ReportLayoutEngine(snapshot: snapshot(photos: [before, after, second.0, second.1], pairs: pairs, template: .beforeAfter),
                                       logoAspect: nil).makePages()
        let perPage = photoRects(pages)
        XCTAssertEqual(perPage[0].count, 2, "First pair with the title block")
        XCTAssertEqual(perPage.filter { !$0.isEmpty }.count, 2, "One pair per page")
        for (id, rect) in perPage.flatMap({ $0 }) {
            let info = [before, after, second.0, second.1].first { $0.id == id }!
            XCTAssertEqual(rect.width / rect.height, info.aspectRatio, accuracy: 0.02)
            XCTAssertGreaterThanOrEqual(rect.height, ReportStyle.minPairImageHeight - 1)
        }
        let labels = pages.flatMap(\.elements).compactMap { element -> String? in
            if case let .text(string, _) = element { return string.string } else { return nil }
        }
        XCTAssertEqual(labels.filter { $0 == "BEFORE" }.count, 2)
        XCTAssertEqual(labels.filter { $0 == "AFTER" }.count, 2)
    }

    /// A06/A08: manual and imported values are marked in the report text itself.
    func testManualAndImportedValuesAreMarkedInReport() {
        var manualPlace = PhotoLocation(source: .manual)
        manualPlace.addressOverride = "Site office"
        manualPlace.addressOverrideKind = .manual
        let manual = ReportSnapshot.PhotoInfo(id: UUID(), originalPath: "Originals/m.jpg", orientedWidth: 4032, orientedHeight: 3024,
                                              caption: "", isImported: true,
                                              dateInfo: PhotoDateInfo(kind: .manual, local: LocalDateTime(iso: "2026-10-01T09:00:00"),
                                                                      offsetSeconds: nil),
                                              location: manualPlace)
        let noZone = ReportSnapshot.PhotoInfo(id: UUID(), originalPath: "Originals/n.jpg", orientedWidth: 3024, orientedHeight: 4032,
                                              caption: "", isImported: true,
                                              dateInfo: PhotoDateInfo(kind: .importedNoOffset, local: LocalDateTime(iso: "2026-10-02T10:00:00"),
                                                                      offsetSeconds: nil),
                                              location: nil)
        let unknown = ReportSnapshot.PhotoInfo(id: UUID(), originalPath: "Originals/u.jpg", orientedWidth: 3024, orientedHeight: 4032,
                                               caption: "", isImported: true, dateInfo: PhotoDateInfo(kind: .unavailable, local: nil, offsetSeconds: nil),
                                               location: nil)
        var report = snapshot(photos: [manual, noZone, unknown])
        report.settings.includePhotoLocations = true
        let text = ReportLayoutEngine(snapshot: report, logoAspect: nil).makePages().flatMap(\.elements).compactMap { element -> String? in
            if case let .text(string, _) = element { return string.string } else { return nil }
        }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Manual date, Imported"), text)
        XCTAssertTrue(text.contains("Site office") && text.contains("Manual location"), text)
        XCTAssertTrue(text.contains("Imported; time zone unknown"), text)
        XCTAssertTrue(text.contains("Capture time unavailable"), text)
    }

    func testReportLanguageIsIndependentOfAppLanguage() {
        let pages = ReportLayoutEngine(snapshot: snapshot(photos: [photo(0)], template: .standard, language: .de), logoAspect: nil).makePages()
        let text = pages.flatMap(\.elements).compactMap { element -> String? in
            if case let .text(string, _) = element { return string.string } else { return nil }
        }.joined(separator: " ")
        XCTAssertTrue(text.contains("Aufgenommen"), text)
        XCTAssertTrue(text.contains("Gerätezeit"), text)
        XCTAssertTrue(text.contains("Bericht erstellt"), text)
    }

    func testFileNames() {
        let id = UUID(uuidString: "A7F2C3D4-0000-0000-0000-000000000000")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!
        XCTAssertEqual(ReportNaming.fileName(projectTitle: "Apartment 24", date: date, reportID: id, calendar: calendar), "Apartment-24_2026-10-08_A7F2.pdf")
        XCTAssertEqual(ReportNaming.fileName(projectTitle: "Квартира №5", date: date, reportID: id, calendar: calendar), "Kvartira-5_2026-10-08_A7F2.pdf")
        XCTAssertEqual(ReportNaming.fileName(projectTitle: "Café / Küche", date: date, reportID: id, calendar: calendar), "Cafe-Kuche_2026-10-08_A7F2.pdf")
        XCTAssertEqual(ReportNaming.fileName(projectTitle: "   ", date: date, reportID: id, calendar: calendar), "Report_2026-10-08_A7F2.pdf")
        let long = ReportNaming.fileName(projectTitle: String(repeating: "a", count: 100), date: date, reportID: id, calendar: calendar)
        XCTAssertLessThanOrEqual(long.count, 40 + 21)
        XCTAssertNotEqual(ReportNaming.fileName(projectTitle: "X", date: date, reportID: UUID(), calendar: calendar),
                          ReportNaming.fileName(projectTitle: "X", date: date, reportID: UUID(), calendar: calendar))
    }
}

/// Builds real PDFs from real image files.
@MainActor
final class ReportGenerationTests: XCTestCase {
    private func makeProject(_ env: TestEnvironment, photos count: Int, caption: (Int) -> String = { _ in "" }) throws -> (Project, [PhotoRecord]) {
        var draft = ProjectDraft()
        draft.title = "Apartment 24"
        draft.siteAddress = "1 Main St"
        let project = try env.repository.createProject(draft, makeFreeProject: true)
        var photos: [PhotoRecord] = []
        for index in 0..<count {
            photos.append(try env.addPhoto(projectID: project.id, width: index % 2 == 0 ? 1600 : 1200, height: index % 2 == 0 ? 1200 : 1600,
                                           caption: caption(index)))
        }
        return (project, photos)
    }

    private func generate(_ snapshot: ReportSnapshot, env: TestEnvironment) throws -> (URL, ReportBuilder.Result) {
        let url = env.files.tempRoot.appendingPathComponent("\(UUID().uuidString).pdf")
        let result = try ReportBuilder(snapshot: snapshot, files: env.files).build(to: url, progress: { _, _ in }, isCancelled: { false })
        return (url, result)
    }

    /// A03 (data part): a standard PDF is created locally, text is real and searchable.
    func testStandardPDFHasTextAndAllPages() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, photos) = try makeProject(env, photos: 5) { "Room \($0) cleaned" }
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        settings.language = .en
        let snapshot = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        let (url, result) = try generate(snapshot, env: env)
        XCTAssertTrue(ReportBuilder.verify(url: url, expectedPages: result.pageCount))
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, result.pageCount)
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Room 3 cleaned"))
        XCTAssertTrue(text.contains("Device time"))
        XCTAssertTrue(text.contains("Created with"), "Free reports carry the footer line")
        XCTAssertTrue(text.contains("1 / \(result.pageCount)"))
        XCTAssertFalse(text.contains("1 Main St"), "Project address is off by default")
        // JPEG pass-through keeps the size reasonable (well below raw bitmaps).
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, 5_000_000)
    }

    func testCyrillicAndDiacriticsAreSearchable() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let captions = ["Кухня — генеральная уборка", "Küche gründlich gereinigt", "Salle de bain détartrée"]
        let (project, photos) = try makeProject(env, photos: 3) { captions[$0] }
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        settings.language = .ru
        let snapshot = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        let (url, _) = try generate(snapshot, env: env)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        for caption in captions { XCTAssertTrue(text.contains(caption), "Missing \(caption)") }
        XCTAssertTrue(text.contains("Время устройства"))
    }

    func testProRemovesFooterAndPreviewIsWatermarked() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, photos) = try makeProject(env, photos: 2)
        try env.repository.createPair(projectID: project.id, before: photos[0].id, after: photos[1].id, title: "Kitchen", caption: "Done")
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        settings.selectedPairIDs = env.repository.pairs(projectID: project.id).map(\.id)
        settings.language = .en

        let pro = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        XCTAssertFalse(pro.branding.showCreatedWith)
        let (proURL, _) = try generate(pro, env: env)
        let proText = PDFDocument(url: proURL)!.page(at: 0)!.string ?? ""
        XCTAssertFalse(proText.contains("Created with"))

        settings.template = .beforeAfter
        let preview = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        XCTAssertTrue(preview.isProPreview)
        let (previewURL, _) = try generate(preview, env: env)
        let previewText = PDFDocument(url: previewURL)!.page(at: 0)!.string ?? ""
        XCTAssertTrue(previewText.contains("PREVIEW"))
        XCTAssertTrue(previewText.contains("BEFORE") && previewText.contains("AFTER"))
    }

    func testLimitsAreCheckedBeforeRendering() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, photos) = try makeProject(env, photos: 21)
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        // 21 photos: the project is over the Free limit → read-only in Free, no new report.
        XCTAssertAppError(.projectReadOnly) {
            try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        }
        XCTAssertNoThrow(try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true))
        settings.selectedPhotoIDs = []
        XCTAssertAppError(.reportNothingSelected) {
            try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        }
        settings.template = .beforeAfter
        XCTAssertAppError(.reportNothingSelected) {
            try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: true)
        }
    }

    func testMissingPhotoFailsInsteadOfLeavingAHole() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, photos) = try makeProject(env, photos: 3)
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        let snapshot = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        try FileManager.default.removeItem(at: env.files.url(forRelative: photos[1].originalPath))
        XCTAssertAppError(.reportPhotoMissing) { try generate(snapshot, env: env) }
    }

    /// A14: cancelling never leaves a report or a broken file in Reports.
    func testCancelledJobRegistersNothing() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, photos) = try makeProject(env, photos: 4)
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        let snapshot = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        let url = env.files.tempRoot.appendingPathComponent("cancel.pdf")
        XCTAssertAppError(.reportCancelled) {
            try ReportBuilder(snapshot: snapshot, files: env.files).build(to: url, progress: { _, _ in }, isCancelled: { true })
        }
        XCTAssertTrue(env.repository.reports(projectID: project.id).isEmpty)
        XCTAssertTrue(env.files.relativeFiles(in: .reports).isEmpty)
    }

    func testJobRegistersVerifiedReportVersion() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let (project, photos) = try makeProject(env, photos: 3)
        var settings = ReportSettings()
        settings.selectedPhotoIDs = photos.map(\.id)
        let snapshot = try ReportSnapshotFactory.make(project: project, settings: settings, repository: env.repository, isPro: false)
        let job = ReportGenerationJob(snapshot: snapshot, repository: env.repository, analytics: LocalAnalyticsService())
        job.start()
        for _ in 0..<200 where job.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .ready(let output) = job.phase else { return XCTFail("Unexpected phase \(job.phase)") }
        let report = try XCTUnwrap(env.repository.report(id: output.reportID))
        XCTAssertTrue(env.files.fileExists(relative: report.pdfPath))
        XCTAssertTrue(env.files.fileExists(relative: report.snapshotPath))
        XCTAssertEqual(report.includedPhotoIDList, photos.map(\.id))
        XCTAssertTrue(report.fileName.hasPrefix("Apartment-24_"))
        XCTAssertGreaterThan(report.bytes, 0)
        // A new export is a new version; the old one stays.
        let second = ReportGenerationJob(snapshot: try ReportSnapshotFactory.make(project: project, settings: settings,
                                                                                    repository: env.repository, isPro: false),
                                         repository: env.repository, analytics: LocalAnalyticsService())
        second.start()
        for _ in 0..<200 where second.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(env.repository.reports(projectID: project.id).count, 2)
    }
}
