import XCTest

/// Drives the app at a steady pace while `simctl io recordVideo` records footage for the App Store
/// preview. Runs only when TEST_RUNNER_PROMO_MARKS is set (the runner sees PROMO_MARKS: a JSON file
/// that receives the wall-clock time of each step, used to cut the recording); skipped otherwise.
/// Uses the Debug sample project and the Debug-only subscriber preview, like MarketingCaptureUITests.
final class PromoRecordingUITests: XCTestCase {
    private var marksURL: URL!
    private var marks: [String: Double] = [:]

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["PROMO_MARKS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_PROMO_MARKS to record the App Store preview footage")
        }
        marksURL = URL(fileURLWithPath: path)
        continueAfterFailure = false
    }

    private func mark(_ name: String) {
        marks[name] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: marksURL)
        }
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    /// Slow, even drag so the scroll reads well on video.
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat, velocity: CGFloat = 500) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0.3)
    }

    func testRecordPreviewFlow() {
        // 1. Onboarding capture demo: viewfinder, focus, flash, stamp, "Saved".
        var app = launch(["-uitest-reset"])
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10))
        mark("onboarding")
        sleep(7)
        app.terminate()

        // 2. Sample project with before/after photos.
        app = launch(["-uitest-reset", "-uitest-skip-onboarding", "-uitest-seed", "-uitest-showcase", "-uitest-pro-preview"])
        app.tabBars.buttons.element(boundBy: 1).tap()
        let row = app.buttons["project.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        sleep(2)
        mark("projects")
        row.tap()
        XCTAssertTrue(app.buttons["photo.cell"].firstMatch.waitForExistence(timeout: 10))
        mark("project")
        sleep(3)

        // 3. One photo with its stamp.
        app.buttons.matching(identifier: "photo.cell").element(boundBy: 1).tap()
        mark("photo")
        sleep(4)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)

        // 4. Before/after pairs.
        let tabs = app.segmentedControls["project.tabs"]
        if tabs.waitForExistence(timeout: 5) {
            tabs.buttons.element(boundBy: 1).tap()
            mark("pairs")
            sleep(3)
            tabs.buttons.element(boundBy: 0).tap()
            sleep(1)
        }

        // 5. Report settings → generate → the finished PDF, scrolled through.
        app.buttons["project.createReport"].tap()
        XCTAssertTrue(app.segmentedControls["report.template"].waitForExistence(timeout: 5))
        mark("reportSettings")
        sleep(1)
        app.segmentedControls["report.template"].buttons.element(boundBy: 1).tap()
        sleep(2)
        mark("generate")
        app.buttons["report.generate"].tap()
        XCTAssertTrue(app.buttons["report.done"].waitForExistence(timeout: 60))
        mark("reportReady")
        sleep(3)
        drag(app, from: 0.72, to: 0.32, velocity: 450)
        sleep(2)
        drag(app, from: 0.72, to: 0.32, velocity: 450)
        sleep(2)
        mark("end")
    }
}
