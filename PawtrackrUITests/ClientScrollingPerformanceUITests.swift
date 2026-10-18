import XCTest

/// Repeatable Simulator measurements use the disposable UI store and never create real clients.
@MainActor
final class ClientScrollingPerformanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-pawtrackr-ui-testing", "--mock-storekit-premium",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_START_TAB"] = "clients"
        app.launch()
        let add = app.buttons["clients.fab.addClient"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.textFields["newClient.firstName"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws { app?.terminate(); app = nil }

    func testKeyboardOpenFormScrollingPerformance() {
        let form = app.scrollViews.containing(.textField, identifier: "newClient.firstName").firstMatch
        let first = app.textFields["newClient.firstName"]
        first.tap()
        first.typeText("Clara")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
                          XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<3 { form.swipeDown() }
            first.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let top = app.navigationBars["New Client"].frame.maxY + 20
            let bottom = app.keyboards.firstMatch.frame.minY - 20
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: bottom))
            let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: top))
            startMeasuring()
            start.press(forDuration: 0.1, thenDragTo: end)
            stopMeasuring()
        }
        XCTAssertEqual(first.value as? String, "Clara")
    }
}
