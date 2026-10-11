import XCTest

/// Drives the main flows in the Simulator and saves screenshots of real screens.
/// Screenshots go to $SCREENSHOT_DIR (pass TEST_RUNNER_SCREENSHOT_DIR to xcodebuild) and to the test result.
final class WalkthroughUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String], language: String = "en", region: String = "US", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_\(region)"] + extra
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    private func tab(_ app: XCUIApplication, _ index: Int) {
        app.tabBars.buttons.element(boundBy: index).tap()
    }

    /// Opens the paywall the way a user does: a second active project in Free (the seeded sample
    /// project is the Free project). Prices come from the StoreKit test configuration.
    private func openPaywallFromSecondProject(_ app: XCUIApplication, name: String) {
        app.buttons["projects.new"].tap()
        let title = app.textFields["project.field.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Site 2")
        app.buttons["project.save"].tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 10))
        sleep(2)
        snap("\(name)_paywall")
        app.swipeUp()
        snap("\(name)_paywall_more")
        app.swipeUp()
        app.swipeUp()
        // Purchase and Restore are reachable by scrolling, also with large text.
        XCTAssertTrue(app.buttons["Restore Purchases"].exists || !name.hasPrefix("a11y"))
        snap("\(name)_paywall_end")
        app.buttons["paywall.close"].tap()
        app.buttons["project.cancel"].tap()
    }

    func test01_OnboardingAndCameraWithoutHardware() {
        let app = launch(["-uitest-reset"])
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10))
        sleep(3) // let the sample scene finish its animation
        snap("en_01_onboarding_capture")
        app.buttons["onboarding.next"].tap()
        sleep(4)
        snap("en_02_onboarding_report")
        app.buttons["onboarding.next"].tap()
        // The Simulator has no camera: import stays available.
        XCTAssertTrue(app.staticTexts["Camera unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Import photos"].exists)
        snap("en_03_camera_unavailable")
        app.buttons["Saving to: Unsorted"].tap()
        XCTAssertTrue(app.navigationBars["Save photos to"].waitForExistence(timeout: 5))
        snap("en_04_camera_target_picker")
        app.buttons["Done"].tap()
        app.buttons["Location: No location"].tap()
        XCTAssertTrue(app.navigationBars["Location"].waitForExistence(timeout: 5))
        snap("en_05_location_sheet")
        app.buttons["Done"].tap()
        app.buttons["Stamp settings"].tap()
        XCTAssertTrue(app.navigationBars["Stamp"].waitForExistence(timeout: 5))
        snap("en_06_stamp_settings")
    }

    /// A01 + U4 + A30: Free creates one project without registration; the second shows Pro and keeps the draft.
    func test02_FreeProjectLimitKeepsDraft() {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding"])
        tab(app, 1)
        XCTAssertTrue(app.buttons["projects.new"].waitForExistence(timeout: 10))
        snap("en_07_projects_empty")
        app.buttons["projects.new"].tap()
        let title = app.textFields["project.field.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Apartment 24")
        snap("en_08_project_create")
        app.buttons["project.save"].tap()
        XCTAssertTrue(app.navigationBars["Apartment 24"].waitForExistence(timeout: 5))
        snap("en_09_project_empty")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["projects.new"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Second site")
        app.buttons["project.save"].tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 5))
        snap("en_10_paywall_second_project")
        app.buttons["paywall.close"].tap()
        // Closing the paywall keeps the typed draft.
        XCTAssertEqual(app.textFields["project.field.title"].value as? String, "Second site")
        app.buttons["project.cancel"].tap()

        // Owner decision (replaces A30): one Free project in total — archiving it does not allow a
        // new one; the paywall says so explicitly and the draft is kept.
        app.buttons["project.row"].firstMatch.tap()
        app.navigationBars["Apartment 24"].buttons["More"].tap()
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["Archived"].firstMatch.waitForExistence(timeout: 5))
        snap("en_10b_project_archived")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["projects.new"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Second site")
        app.buttons["project.save"].tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 5), "Archiving does not free the Free project")
        snap("en_10c_paywall_after_archive")
        app.buttons["paywall.close"].tap()
        XCTAssertEqual(app.textFields["project.field.title"].value as? String, "Second site")
        app.buttons["project.cancel"].tap()
        snap("en_10d_free_plan_summary")
    }

    func test03_SampleProjectReportAndPairs() {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed"])
        tab(app, 1)
        let row = app.buttons["project.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        snap("en_11_projects_list")
        row.tap()
        XCTAssertTrue(app.buttons["photo.cell"].firstMatch.waitForExistence(timeout: 10))
        snap("en_12_project_photos")

        app.buttons["photo.cell"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Photo"].waitForExistence(timeout: 5))
        snap("en_13_photo_detail")
        app.swipeUp()
        snap("en_14_photo_detail_more")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.segmentedControls["project.tabs"].buttons.element(boundBy: 1).tap()
        snap("en_15_project_pairs")
        app.segmentedControls["project.tabs"].buttons.element(boundBy: 0).tap()

        app.buttons["project.createReport"].tap()
        XCTAssertTrue(app.buttons["report.generate"].waitForExistence(timeout: 5))
        snap("en_16_report_settings")
        app.swipeUp()
        snap("en_17_report_settings_privacy")
        app.buttons["report.generate"].tap()
        XCTAssertTrue(app.otherElements["report.ready"].waitForExistence(timeout: 60) || app.staticTexts["Report ready"].waitForExistence(timeout: 5))
        sleep(1)
        snap("en_18_report_ready")
        // A16: the real system share sheet is closed without sharing; the ready PDF stays.
        app.buttons["Share"].firstMatch.tap()
        // The share sheet is a system view in the system language: find its close button by identifier.
        let closeShare = app.buttons["header.closeButton"].firstMatch
        XCTAssertTrue(closeShare.waitForExistence(timeout: 15))
        snap("en_18b_share_sheet")
        closeShare.tap()
        XCTAssertTrue(app.otherElements["report.ready"].waitForExistence(timeout: 10) || app.staticTexts["Report ready"].exists)
        app.buttons["report.done"].tap()

        // Before/After in Free: preview with a Pro mark.
        app.buttons["project.createReport"].tap()
        XCTAssertTrue(app.segmentedControls["report.template"].waitForExistence(timeout: 5))
        app.segmentedControls["report.template"].buttons.element(boundBy: 1).tap()
        snap("en_19_report_settings_before_after")
        app.buttons["report.generate"].tap()
        XCTAssertTrue(app.otherElements["report.previewBanner"].waitForExistence(timeout: 60) || app.staticTexts["Preview with Pro mark"].waitForExistence(timeout: 5))
        sleep(1)
        snap("en_20_before_after_preview")
        app.buttons["report.done"].tap()

        app.segmentedControls["project.tabs"].buttons.element(boundBy: 2).tap()
        snap("en_21_project_reports")
    }

    func test04_SettingsScreens() {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed"])
        tab(app, 2)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        snap("en_22_settings")
        // The Pro banner opens the paywall (no subscription screen and no in-app "manage").
        app.buttons["settings.proBanner"].firstMatch.tap()
        XCTAssertTrue(app.buttons["paywall.close"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Manage subscription"].exists)
        snap("en_28_paywall_from_banner")
        app.buttons["paywall.close"].tap()
        let screens: [(String, String)] = [("Privacy & storage", "en_23_privacy"), ("Backups", "en_24_backups"),
                                           ("Support", "en_25_support"), ("Help", "en_26_help"), ("Your profile", "en_27_profile"),
                                           ("Brand presets", "en_29_brand_presets")]
        for (label, name) in screens {
            let cell = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch : app.staticTexts[label].firstMatch
            if !cell.isHittable { app.swipeUp() }
            cell.tap()
            sleep(1)
            snap(name)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    /// A26: all five languages on the main screens (also checks for clipped buttons by eye).
    func test05_Languages() {
        for (language, region) in [("ru", "RU"), ("de", "DE"), ("fr", "FR"), ("es", "ES")] {
            let app = launch(["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed"], language: language, region: region)
            tab(app, 1)
            XCTAssertTrue(app.buttons["project.row"].firstMatch.waitForExistence(timeout: 10))
            snap("\(language)_01_projects")
            openPaywallFromSecondProject(app, name: "\(language)_07")
            app.buttons["project.row"].firstMatch.tap()
            XCTAssertTrue(app.buttons["photo.cell"].firstMatch.waitForExistence(timeout: 10))
            snap("\(language)_02_project")
            app.buttons["project.createReport"].tap()
            XCTAssertTrue(app.buttons["report.generate"].waitForExistence(timeout: 5))
            snap("\(language)_03_report_settings")
            app.buttons["report.generate"].tap()
            XCTAssertTrue(app.buttons["report.done"].waitForExistence(timeout: 60))
            sleep(1)
            snap("\(language)_04_report_pdf")
            app.buttons["report.done"].tap()
            tab(app, 2)
            sleep(1)
            snap("\(language)_05_settings")
            tab(app, 0)
            sleep(1)
            snap("\(language)_06_camera")
            app.terminate()
        }
    }

    /// Dynamic Type at a large accessibility size.
    func test06_LargeText() {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed"],
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        tab(app, 1)
        sleep(1)
        for _ in 0..<4 where !app.buttons["project.row"].firstMatch.exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["project.row"].firstMatch.waitForExistence(timeout: 10))
        snap("a11y_01_projects_large_text")
        openPaywallFromSecondProject(app, name: "a11y_04")
        for _ in 0..<4 where !app.buttons["project.row"].firstMatch.isHittable { app.swipeUp() }
        app.buttons["project.row"].firstMatch.tap()
        sleep(1)
        snap("a11y_02_project_large_text")
        tab(app, 0)
        sleep(1)
        snap("a11y_03_camera_large_text")
    }

    /// Dark appearance of the main screens (the PDF stays light).
    func test07_DarkMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-AppleInterfaceStyle", "Dark"]
        app.launch()
        tab(app, 1)
        XCTAssertTrue(app.buttons["project.row"].firstMatch.waitForExistence(timeout: 10))
        snap("dark_01_projects")
        app.buttons["project.row"].firstMatch.tap()
        sleep(1)
        snap("dark_02_project")
    }

    /// A27: the Simulator has no mail account and no Mail app. The support address can still be
    /// copied and the mail button explains itself; an unconfigured build says so (never a dead button).
    /// The configured path runs when the build has WP_SUPPORT_EMAIL (see README).
    func test08_SupportWithoutMailApp() throws {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding"])
        tab(app, 2)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let cell = app.buttons["Support"].firstMatch
        if !cell.isHittable { app.swipeUp() }
        cell.tap()
        XCTAssertTrue(app.navigationBars["Support"].waitForExistence(timeout: 10))
        app.swipeUp()
        app.swipeUp()
        let copy = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Copy support email")).firstMatch
        guard copy.waitForExistence(timeout: 3) else {
            XCTAssertTrue(app.staticTexts["Support contact isn't configured in this build."].exists)
            snap("en_30_support_not_configured")
            throw XCTSkip("WP_SUPPORT_EMAIL is not set in this build: only the 'not configured' notice was checked.")
        }
        XCTAssertFalse(app.buttons["Write email"].exists, "No in-app composer without a mail account")
        copy.tap()
        XCTAssertTrue(app.staticTexts["Address copied"].waitForExistence(timeout: 5))
        snap("en_30_support_copy")
        let openMail = app.buttons["Write in the mail app"]
        XCTAssertTrue(openMail.waitForExistence(timeout: 5))
        openMail.tap()
        XCTAssertTrue(app.staticTexts["No mail app opened. Copy the address instead."].waitForExistence(timeout: 5))
        snap("en_31_support_no_mail_app")
    }

    /// The interface language can be changed inside the app; the UI switches at once and the
    /// Settings tab stays open. Profile and brand presets open from Settings in every language.
    func test09_InAppLanguage() {
        let app = launch(["-uitest-reset", "-uitest-skip-onboarding"])
        tab(app, 2)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App language")).firstMatch.tap()
        let russian = app.buttons["Русский"].firstMatch
        XCTAssertTrue(russian.waitForExistence(timeout: 5))
        snap("en_32_language_menu")
        russian.tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 10), "The UI switched to Russian")
        XCTAssertTrue(app.tabBars.buttons["Камера"].exists)
        snap("ru_08_settings_in_app_language")
        let profileRow = app.buttons["settings.profile"]
        for _ in 0..<4 where !profileRow.isHittable { app.swipeUp() }
        profileRow.tap()
        XCTAssertTrue(app.navigationBars["Профиль исполнителя"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let presetsRow = app.buttons["settings.brandPresets"]
        for _ in 0..<4 where !presetsRow.isHittable { app.swipeUp() }
        presetsRow.tap()
        XCTAssertTrue(app.navigationBars["Фирменные пресеты"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tab(app, 1)
        XCTAssertTrue(app.navigationBars["Проекты"].waitForExistence(timeout: 10))
        tab(app, 2)
        let languageRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Язык приложения")).firstMatch
        for _ in 0..<4 where !languageRow.isHittable { app.swipeDown() }
        languageRow.tap()
        let device = app.buttons["Как на устройстве"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        device.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Back to the iPhone language")
    }
}
