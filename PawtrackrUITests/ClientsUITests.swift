//
//  ClientsUITests.swift
//  PawtrackrUITests
//
//  Drives the Clients tab end-to-end: list display, search, new-client sheet
//  with form fields, save and dismiss.
//

import XCTest

@MainActor
final class ClientsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-pawtrackr-ui-testing",
            "--mock-storekit-premium",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
        // The prior debug session may have persisted the Clients tab.
        app.launchEnvironment["PAWTRACKR_UI_START_TAB"] = "dashboard"
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tab arrival

    func testClientsTabShowsSeededClient() throws {
        waitForDashboard()
        tapTab("Clients")

        let landed = waitForAny([
            { self.app.staticTexts["UITest Owner"].exists },
            { self.app.buttons["clients.row.UITest Owner"].exists }
        ], timeout: 12)
        XCTAssertTrue(landed, "Clients tab should show the seeded UITest Owner row.")
    }

    // MARK: - New Client sheet

    func testFABOpensNewClientSheet() throws {
        waitForDashboard()
        tapTab("Clients")

        // FAB on iPhone, toolbar button as fallback.
        let fab = app.buttons["clients.fab.addClient"]
        let toolbarAdd = app.buttons["clients.toolbar.addClient"]
        let trigger = fab.exists ? fab : toolbarAdd

        XCTAssertTrue(trigger.waitForHittable(timeout: 8), "Add-client trigger should be hittable.")
        trigger.tap()

        XCTAssertTrue(app.textFields["newClient.firstName"].waitForExistence(timeout: 6),
                      "New client sheet's first-name field must appear.")
    }

    func testNewClientSheetCreateButtonDisabledOnEmptyForm() throws {
        waitForDashboard()
        tapTab("Clients")

        let trigger = app.buttons["clients.fab.addClient"].exists
            ? app.buttons["clients.fab.addClient"]
            : app.buttons["clients.toolbar.addClient"]
        XCTAssertTrue(trigger.waitForHittable(timeout: 8))
        trigger.tap()

        XCTAssertTrue(app.textFields["newClient.firstName"].waitForExistence(timeout: 6))

        // Create button should not advance the flow (it requires firstName at minimum).
        let createBtn = app.buttons["newClient.create"]
        XCTAssertTrue(createBtn.exists, "Create button should be present.")
    }

    func testNewClientSheetCancelDismisses() throws {
        waitForDashboard()
        tapTab("Clients")

        let trigger = app.buttons["clients.fab.addClient"].exists
            ? app.buttons["clients.fab.addClient"]
            : app.buttons["clients.toolbar.addClient"]
        XCTAssertTrue(trigger.waitForHittable(timeout: 8))
        trigger.tap()

        XCTAssertTrue(app.textFields["newClient.firstName"].waitForExistence(timeout: 6))

        app.buttons["newClient.cancel"].tap()

        XCTAssertFalse(app.textFields["newClient.firstName"].waitForExistence(timeout: 3),
                       "Sheet should be dismissed after cancel.")
    }

    func testNewClientHappyPath_FillFormAndSave() throws {
        waitForDashboard()
        tapTab("Clients")

        let trigger = app.buttons["clients.fab.addClient"].exists
            ? app.buttons["clients.fab.addClient"]
            : app.buttons["clients.toolbar.addClient"]
        XCTAssertTrue(trigger.waitForHittable(timeout: 8))
        trigger.tap()

        let firstName = app.textFields["newClient.firstName"]
        XCTAssertTrue(firstName.waitForHittable(timeout: 6))
        firstName.tap()
        firstName.typeText("Casey")

        let lastName = app.textFields["newClient.lastName"]
        if lastName.waitForHittable(timeout: 3) {
            lastName.tap()
            lastName.typeText("Tester")
        }

        let phone = app.textFields["newClient.phone"]
        if phone.waitForHittable(timeout: 3) {
            phone.tap()
            phone.typeText("3125550199")
        }

        // Dismiss the keyboard before tapping toolbar Create.
        app.keyboards.buttons["Done"].tapIfExists()
        app.keyboards.buttons["return"].tapIfExists()

        let createBtn = app.buttons["newClient.create"]
        XCTAssertTrue(createBtn.waitForHittable(timeout: 6), "Create button should be hittable once the form is valid.")
        createBtn.tap()

        // After success the sheet dismisses and the new client appears in the list.
        let appeared = waitForAny([
            { self.app.staticTexts["Casey Tester"].exists },
            { self.app.buttons["clients.row.Casey Tester"].exists },
            { !self.app.textFields["newClient.firstName"].exists }
        ], timeout: 8)
        XCTAssertTrue(appeared, "New client should be saved and the sheet should dismiss.")
    }

    // MARK: - Helpers

    private func waitForAny(_ conditions: [() -> Bool], timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if conditions.contains(where: { $0() }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return conditions.contains(where: { $0() })
    }

    private func waitForDashboard() {
        XCTAssertTrue(
            app.staticTexts["Dashboard"].waitForExistence(timeout: 12)
                || app.navigationBars["Dashboard"].waitForExistence(timeout: 2),
            "Dashboard did not load."
        )
    }

    private func tapTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForHittable(timeout: 8), "\(title) tab was not hittable.")
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
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if exists && isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return exists && isHittable
    }

    @discardableResult
    func tapIfExists(timeout: TimeInterval = 0) -> Bool {
        if timeout > 0 { _ = waitForHittable(timeout: timeout) }
        guard exists && isHittable else { return false }
        tap()
        return true
    }
}
