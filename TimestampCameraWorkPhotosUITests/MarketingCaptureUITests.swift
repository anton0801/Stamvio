import XCTest

/// Real-app screens for the website and the App Store preview. Runs only when
/// TEST_RUNNER_MARKETING_DIR is set (the runner sees MARKETING_DIR); skipped in normal test runs.
/// Uses the Debug showcase project and the Debug-only subscriber preview.
final class MarketingCaptureUITests: XCTestCase {
    private var directory: URL!
    private var language: String {
        let requested = ProcessInfo.processInfo.environment["MARKETING_LANG"] ?? "en"
        return ["en", "es", "ru", "de", "fr"].contains(requested) ? requested : "en"
    }

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MARKETING_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MARKETING_DIR to capture marketing screens")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        continueAfterFailure = false
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        let locales = ["en": "en_US", "es": "es_ES", "ru": "ru_RU", "de": "de_DE", "fr": "fr_FR"]
        app.launchArguments = arguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", locales[language]!]
        app.launch()
        return app
    }

    func test1_Onboarding() {
        let app = launch(["-uitest-reset"])
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10))
        sleep(3)
        snap("m01_capture")
        app.buttons["onboarding.next"].tap()
        sleep(4)
        snap("m02_report_demo")
    }

    func test2_ProjectPhotoReport() {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed", "-uitest-showcase", "-uitest-pro-preview"])
        app.tabBars.buttons.element(boundBy: 1).tap()
        let row = app.buttons["project.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["photo.cell"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        snap("m03_project")
        app.buttons.matching(identifier: "photo.cell").element(boundBy: 1).tap()
        sleep(2)
        snap("m04_photo")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let tabs = app.segmentedControls["project.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons.element(boundBy: 1).tap()
        sleep(2)
        snap("m08_pairs")
        tabs.buttons.element(boundBy: 0).tap()
        app.buttons["project.createReport"].tap()
        XCTAssertTrue(app.segmentedControls["report.template"].waitForExistence(timeout: 5))
        app.segmentedControls["report.template"].buttons.element(boundBy: 1).tap()
        // Marketing-only workaround approved after inspecting the Spanish A4 PDF:
        // its first pair's note spills onto a nearly empty continuation page.
        if ProcessInfo.processInfo.environment["MARKETING_LETTER"] == "1" {
            let pageLabels = ["en": "Page size", "es": "Tamaño de página", "ru": "Формат страницы",
                              "de": "Seitenformat", "fr": "Format de page"]
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", pageLabels[language]!)).firstMatch
            for _ in 0..<8 {
                if picker.exists && picker.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.isHittable)
            picker.tap()
            let letter = app.buttons[language == "es" ? "Carta (EE. UU.)" : "US Letter"]
            XCTAssertTrue(letter.waitForExistence(timeout: 5))
            letter.tap()
            for _ in 0..<8 {
                if app.segmentedControls["report.template"].isHittable { break }
                app.swipeDown()
            }
            XCTAssertTrue(app.segmentedControls["report.template"].isHittable)
            sleep(2) // Let the scroll indicator fade before the marketing screenshot.
        }
        sleep(1)
        snap("m05_report_settings")
        app.buttons["report.generate"].tap()
        XCTAssertTrue(app.buttons["report.done"].waitForExistence(timeout: 60))
        sleep(2)
        snap("m06_report_ready")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
        sleep(2)
        snap("m09_report_page2")
        app.buttons["report.done"].tap()
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(2)
        snap("m07_settings_pro")
        let privacy = app.buttons["settings.privacy"]
        for _ in 0..<8 {
            if privacy.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertTrue(privacy.isHittable)
        privacy.tap()
        let privacyTitles = [
            "en": "Privacy & storage", "es": "Privacidad y almacenamiento",
            "ru": "Приватность и хранилище", "de": "Datenschutz & Speicher",
            "fr": "Confidentialité et stockage"
        ]
        XCTAssertTrue(app.navigationBars[privacyTitles[language]!].waitForExistence(timeout: 10))
        sleep(2)
        snap("m10_privacy")
    }
}
