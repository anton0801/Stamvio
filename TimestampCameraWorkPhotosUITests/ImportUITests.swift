import XCTest

/// Imports the fixtures added to the Simulator library (TestFixtures/Photos) through the system picker.
final class ImportUITests: XCTestCase {
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// Owner decision: 3 free photos in total; the next import (or shot) opens the paywall.
    func testFreePlanAllowsThreePhotosThenPaywall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-skip-onboarding", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        for round in 0..<4 {
            app.buttons["camera.import"].tap()
            if app.buttons["paywall.close"].waitForExistence(timeout: 3) {
                XCTAssertGreaterThan(round, 0, "The paywall appears only after the free photos are used")
                sleep(2)
                snap("free_01_paywall_photos")
                app.swipeUp()
                snap("free_02_paywall_plans")
                return
            }
            let choose = app.buttons["Choose photos"]
            if choose.waitForExistence(timeout: 3) {
                if round == 0 { snap("free_00_limits") }
                choose.tap()
            }
            var images: [XCUIElement] = []
            for _ in 0..<30 {
                sleep(1)
                images = app.images.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 40 }
                if images.count >= 9 { break }
            }
            guard !images.isEmpty else { throw XCTSkip("The system photo picker is not reachable from XCUITest here") }
            if round == 0 { snap("free_00b_picker") }
            // Rejected fixtures (63 MP, GIF, truncated) are not saved and do not use the quota, so every
            // round takes the next photos. Extra taps are ignored: the picker stops at the remaining free photos.
            for image in images.dropFirst(3 * round).prefix(5) { image.tap() }
            let add = app.buttons["Add"]
            if add.exists { add.tap() } else { app.navigationBars.buttons.element(boundBy: 1).tap() }
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 120))
            done.tap()
        }
        XCTFail("The paywall did not appear after the free photos were used")
    }

    func testImportFixturesThroughPicker() throws {
        let app = XCUIApplication()
        // A larger Free photo quota (Debug only) so all fixtures can be imported and checked.
        app.launchArguments = ["-uitest-reset", "-uitest-skip-onboarding", "-uitest-free-photo-quota", "50",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["camera.import"].tap()
        // IMP-01: limits are shown before the system picker (first time after a reset).
        let choose = app.buttons["Choose photos"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        snap("import_00_limits")
        choose.tap()
        var images: [XCUIElement] = []
        for _ in 0..<30 {
            sleep(1)
            images = app.images.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 40 }
            if images.count >= 3 { break }
        }
        snap("import_01_picker")
        guard !images.isEmpty else { throw XCTSkip("The system photo picker is not reachable from XCUITest here") }
        for image in images.prefix(12) { image.tap() }
        snap("import_02_selected")
        let add = app.buttons["Add"]
        if add.exists { add.tap() } else { app.navigationBars.buttons.element(boundBy: 1).tap() }
        XCTAssertTrue(app.navigationBars["Import"].waitForExistence(timeout: 20))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 120))
        snap("import_03_results")
        app.swipeUp()
        snap("import_04_results_more")
        done.tap()
        app.tabBars.buttons.element(boundBy: 1).tap()
        app.buttons["projects.unsorted"].tap()
        sleep(2)
        snap("import_05_unsorted_grid")
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Photo 1'")).firstMatch
        if first.exists {
            first.tap()
            sleep(2)
            snap("import_06_photo_detail")
            app.swipeUp()
            snap("import_07_photo_detail_more")
        }
    }
}
