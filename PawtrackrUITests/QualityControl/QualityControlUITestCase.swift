import XCTest

@MainActor
class QualityControlUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func launch(startTab: String? = nil, onboarding: Bool = false, startWalkthrough: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = [
            "-pawtrackr-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        if onboarding {
            app.launchArguments.append("-pawtrackr-ui-onboarding")
            app.launchArguments.append("--mock-storekit-unknown")
        } else {
            app.launchArguments.append("--mock-storekit-premium")
        }
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        if !onboarding {
            app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
        }
        if let startTab {
            app.launchEnvironment["PAWTRACKR_UI_START_TAB"] = startTab
        }
        if startWalkthrough {
            app.launchEnvironment["PAWTRACKR_UI_START_WALKTHROUGH"] = "1"
        }
        app.launch()
    }

    @discardableResult
    func waitForAny(_ conditions: [() -> Bool], timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if conditions.contains(where: { $0() }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return conditions.contains(where: { $0() })
    }

    @discardableResult
    func waitForDashboard(timeout: TimeInterval = 12) -> Bool {
        unlockIfNeeded()
        return waitForAny([
            { self.app.staticTexts["Dashboard"].exists },
            { self.app.navigationBars["Dashboard"].exists }
        ], timeout: timeout)
    }

    @discardableResult
    func waitForClientsScreen(timeout: TimeInterval = 12) -> Bool {
        waitForAny([
            { self.app.navigationBars["Clients"].exists },
            { self.app.staticTexts["Clients"].exists },
            { self.app.buttons["clients.fab.addClient"].exists },
            { self.app.buttons["clients.toolbar.search"].exists }
        ], timeout: timeout)
    }

    @discardableResult
    func waitForSettingsScreen(timeout: TimeInterval = 12) -> Bool {
        waitForAny([
            { self.app.navigationBars["Settings"].exists },
            { self.app.staticTexts["Business Profile"].exists },
            { self.app.staticTexts["Security"].exists }
        ], timeout: timeout)
    }

    func tapTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        let sidebar = app.buttons["sidebar.row.\(title.lowercased())"]
        if waitUntilHittable(sidebar, timeout: 2) {
            sidebar.tap()
            return
        }
        XCTAssertTrue(waitUntilHittable(tab, timeout: 8), "\(title) tab was not hittable.")
        for attempt in 0..<4 {
            if attempt == 0 || !tab.isHittable {
                tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                tab.tap()
            }
            _ = app.wait(for: .runningForeground, timeout: 0.5)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            if attempt >= 1 { return }
        }
    }

    func tapPrimaryButton(named title: String) {
        let titledButton = app.buttons[title]
        if waitUntilHittable(titledButton, timeout: 8) {
            titledButton.tap()
            return
        }
        let primaryButton = app.buttons["checkout.primaryButton"]
        XCTAssertTrue(waitUntilHittable(primaryButton, timeout: 8), "\(title) primary button was not hittable.")
        primaryButton.tap()
    }

    func openCheckoutFromDashboard() {
        XCTAssertTrue(waitForDashboard(), "Dashboard did not load.")
        let checkoutButton = app.buttons["dashboard.activeSession.checkoutButton"]
        let scrollView = app.scrollViews["dashboard.scroll"]

        for _ in 0..<6 {
            if checkoutButton.exists && checkoutButton.isHittable {
                checkoutButton.tap()
                return
            }
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
        }

        XCTAssertTrue(waitUntilHittable(checkoutButton, timeout: 3), "Active session checkout button did not become hittable.")
        checkoutButton.tap()
    }

    func openSeededClientFromClients() {
        XCTAssertTrue(waitForClientsScreen(), "Clients screen did not load.")

        let row = app.buttons["clients.row.UITest Owner"]
        let staticRow = app.staticTexts["UITest Owner"]

        if waitUntilHittable(row, timeout: 8) {
            row.tap()
        } else if waitUntilHittable(staticRow, timeout: 4) {
            staticRow.tap()
        } else {
            XCTFail("Could not find seeded client row to open.")
        }
    }

    func openPetHistoryFromSeededClient() {
        openSeededClientFromClients()

        let history = app.buttons["clientDetail.pet.UITest Pet.history"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<4 where !history.exists {
            if scroll.exists {
                scroll.swipeUp()
            } else {
                app.swipeUp()
            }
        }

        XCTAssertTrue(waitUntilHittable(history, timeout: 6), "Pet history button should be present.")
        history.tap()
    }

    func dismissKeyboardIfPresent() {
        _ = tapIfHittable(app.keyboards.buttons["Done"], timeout: 0.5)
        _ = tapIfHittable(app.toolbars.buttons["Done"], timeout: 0.5)
    }

    func unlockIfNeeded() {
        if app.staticTexts["Enter PIN"].waitForExistence(timeout: 1) || app.buttons["1"].exists {
            enterPIN("1234")
        }
    }

    private func enterPIN(_ pin: String) {
        for digit in pin {
            let button = app.buttons[String(digit)]
            guard waitUntilHittable(button, timeout: 2) else { return }
            button.tap()
        }
    }

    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    @discardableResult
    func tapIfHittable(_ element: XCUIElement, timeout: TimeInterval = 0) -> Bool {
        if timeout > 0 { _ = waitUntilHittable(element, timeout: timeout) }
        guard element.exists && element.isHittable else { return false }
        element.tap()
        return true
    }

    func replaceText(in element: XCUIElement, with text: String) {
        guard element.exists && element.isHittable else { return }
        element.tap()
        let menuApp = XCUIApplication()
        let selectAll = menuApp.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1) {
            selectAll.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
            _ = tapIfHittable(menuApp.menuItems["Select All"], timeout: 0.5)
        }
        if !text.isEmpty {
            element.typeText(text)
        }
    }
}
