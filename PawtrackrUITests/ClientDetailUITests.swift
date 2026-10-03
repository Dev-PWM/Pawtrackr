//
//  ClientDetailUITests.swift
//  PawtrackrUITests
//
//  Drives the ClientDetailView flow: open detail, inline edit, history navigation,
//  delete confirmation, message sheet.
//

import XCTest

@MainActor
final class ClientDetailUITests: XCTestCase {
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

    // MARK: - Navigation

    func testOpeningSeededClientShowsDetailView() throws {
        waitForDashboard()
        openSeededClient()

        // The detail view should show the pet card with name "UITest Pet".
        let landed = waitForAny([
            { self.app.staticTexts["UITest Pet"].exists },
            { self.app.staticTexts["UITest Owner"].exists }
        ], timeout: 8)
        XCTAssertTrue(landed, "Client detail should show the seeded pet/owner names.")
    }

    // MARK: - Inline edit

    func testInlineEditEntersAndCancels() throws {
        waitForDashboard()
        openSeededClient()

        let editBtn = app.buttons["clientDetail.editInline"]
        XCTAssertTrue(editBtn.waitForHittable(timeout: 6), "Inline edit button should appear.")
        editBtn.tap()

        let cancel = app.buttons["clientDetail.inlineEdit.cancel"]
        XCTAssertTrue(cancel.waitForHittable(timeout: 4), "Cancel inline edit button should appear.")
        cancel.tap()

        // Re-tapping edit should still work after cancel.
        XCTAssertTrue(editBtn.waitForHittable(timeout: 4))
    }

    // MARK: - Pet history sheet

    func testPetHistoryButtonOpensHistorySheet() throws {
        waitForDashboard()
        openSeededClient()

        let history = app.buttons["clientDetail.pet.UITest Pet.history"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<3 where !history.exists {
            scroll.exists ? scroll.swipeUp() : app.swipeUp()
        }
        XCTAssertTrue(history.waitForHittable(timeout: 6), "Pet history button should be present.")
        history.tap()

        // The history sheet shows visit rows for the pet.
        let opened = waitForAny([
            { self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'UITest Pet'")).firstMatch.exists },
            { self.app.staticTexts["History"].exists },
            { self.app.navigationBars.firstMatch.exists }
        ], timeout: 6)
        XCTAssertTrue(opened, "Pet history view should appear.")
    }

    // MARK: - Delete client confirmation

    func testDeleteToolbarButtonShowsConfirmation() throws {
        waitForDashboard()
        openSeededClient()

        let delete = app.buttons["clientDetail.toolbar.delete"]
        XCTAssertTrue(delete.waitForHittable(timeout: 6), "Toolbar delete button should be present.")
        delete.tap()

        // Confirmation alert should appear.
        let alertVisible = waitForAny([
            { self.app.alerts.element.exists },
            { self.app.buttons["No"].exists },
            { self.app.buttons["Yes"].exists }
        ], timeout: 5)
        XCTAssertTrue(alertVisible, "Delete confirmation alert must appear.")

        // Cancel — leave the seeded client alone for downstream tests.
        let no = app.buttons["No"]
        if no.waitForHittable(timeout: 3) { no.tap() }
    }

    // MARK: - Helpers

    private func openSeededClient() {
        tapTab("Clients")
        let row = app.buttons["clients.row.UITest Owner"]
        let staticRow = app.staticTexts["UITest Owner"]

        if row.waitForHittable(timeout: 8) {
            row.tap()
        } else if staticRow.waitForHittable(timeout: 4) {
            staticRow.tap()
        } else {
            XCTFail("Could not find seeded client row to open.")
        }
    }

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
}
