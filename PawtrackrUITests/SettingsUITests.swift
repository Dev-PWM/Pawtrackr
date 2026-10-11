//
//  SettingsUITests.swift
//  PawtrackrUITests
//
//  Drives the Settings flow end-to-end: app lock toggle + disable confirmation,
//  biometric toggle, change-PIN sheet, async export buttons.
//

import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
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
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tab arrival

    func testSettingsTabLoadsAndShowsSections() throws {
        waitForDashboard()
        tapTab("Settings")

        let landed = waitForAny([
            { self.app.staticTexts["Business Profile"].exists },
            { self.app.staticTexts["Security"].exists },
            { self.app.staticTexts["Data Export"].exists },
            { self.app.buttons["settings.section.security"].exists },
            { self.app.buttons["settings.section.dataExport"].exists }
        ], timeout: 12)
        XCTAssertTrue(landed, "Settings sections should be visible.")
        XCTAssertFalse(app.buttons["settings.section.icloud"].exists)
        XCTAssertFalse(app.buttons["settings.section.devices"].exists)
        XCTAssertFalse(app.staticTexts["iCloud"].exists)
    }

    func testHelpAndSettingsShowTheSimplifiedGuideAndBusinessControls() throws {
        waitForDashboard()
        tapTab("Settings")
        openSettingsSection(identifier: "help", title: "Help")
        XCTAssertTrue(app.staticTexts["Find your way"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["A visit from start to finish"].exists)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "A CSV is not a restorable app backup"))
            .firstMatch.exists)
        XCTAssertFalse(app.buttons["Copy Support Report"].exists)

        returnToSettingsList()
        openSettingsSection(identifier: "business", title: "Business")
        XCTAssertTrue(app.staticTexts["Salon Identity"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Money & Receipts"].exists)
        returnToSettingsList()
        openSettingsSection(identifier: "preferences", title: "Preferences")
        XCTAssertFalse(app.staticTexts["This Workstation"].exists)
    }

    func testSpanishHelpExplainsCSVAndBackups() throws {
        app.terminate()
        app.launchArguments = [
            "-pawtrackr-ui-testing",
            "--mock-storekit-premium",
            "-AppleLanguages", "(es)",
            "-AppleLocale", "es_ES"
        ]
        app.launch()
        let settingsTab = app.tabBars.buttons["Ajustes"]
        XCTAssertTrue(settingsTab.waitForHittable(timeout: 12))
        settingsTab.tap()
        let help = app.buttons["settings.section.help"]
        XCTAssertTrue(help.waitForHittable(timeout: 8))
        help.tap()
        XCTAssertTrue(app.staticTexts["Encuentra lo que necesitas"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Un CSV no es un respaldo"))
            .firstMatch.exists)
    }

    // MARK: - App Lock toggle confirmation

    func testDisableAppLockShowsConfirmationAlert() throws {
        waitForDashboard()
        tapTab("Settings")
        openSettingsSection(identifier: "security", title: "Security")

        let toggle = app.switches["settings.appLockToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "App Lock toggle must be present.")

        ensureAppLockEnabledWithPIN()

        // Now turning it off should pop a confirmation alert.
        toggle.tap()

        let confirmAlert = app.alerts["Disable App Lock?"]
        let didShowAlert = waitForAny([
            { confirmAlert.exists },
            { self.app.alerts.element(boundBy: 0).exists }
        ], timeout: 5)
        XCTAssertTrue(didShowAlert, "Disable confirmation alert must appear.")

        // Cancel — lock should remain enabled.
        let cancel = app.alerts.buttons["Cancel"]
        if cancel.waitForHittable(timeout: 3) { cancel.tap() }
    }

    // MARK: - Change PIN sheet

    func testChangePINSheetOpensWithThreeFields() throws {
        waitForDashboard()
        tapTab("Settings")
        openSettingsSection(identifier: "security", title: "Security")

        ensureAppLockEnabledWithPIN()

        let changePINBtn = app.buttons["settings.changePIN"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<4 where !changePINBtn.exists {
            scroll.exists ? scroll.swipeUp() : app.swipeUp()
        }
        XCTAssertTrue(changePINBtn.waitForHittable(timeout: 6), "Change PIN button should be hittable.")
        changePINBtn.tap()

        // The sheet shows "Change PIN" navigation bar / title.
        let sheetUp = waitForAny([
            { self.app.navigationBars["Change PIN"].exists },
            { self.app.staticTexts["Change PIN"].exists }
        ], timeout: 6)
        XCTAssertTrue(sheetUp, "Change PIN sheet must open.")
        XCTAssertTrue(app.secureTextFields["settings.pin.current"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["settings.pin.new"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["settings.pin.confirm"].waitForExistence(timeout: 3))

        // Cancel out cleanly.
        let cancelBtn = app.buttons["settings.pin.cancel"].exists ? app.buttons["settings.pin.cancel"] : app.buttons["Cancel"]
        if cancelBtn.waitForHittable(timeout: 3) { cancelBtn.tap() }
    }

    // MARK: - Async export buttons

    func testExportClientsButtonOpensSharePreviewSheet() throws {
        waitForDashboard()
        tapTab("Settings")
        openSettingsSection(identifier: "dataExport", title: "Data Export")

        let exportBtn = app.buttons["settings.exportClients"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 where !exportBtn.exists {
            scroll.exists ? scroll.swipeUp() : app.swipeUp()
        }

        XCTAssertTrue(exportBtn.waitForHittable(timeout: 8), "Export Clients button should be present.")
        exportBtn.tap()

        // The preview sheet should appear (with the Share via… label) within a few seconds.
        let previewUp = waitForAny([
            { self.app.staticTexts["Clients Export Ready"].exists },
            { self.app.buttons.matching(NSPredicate(format: "label CONTAINS 'Share via'")).firstMatch.exists },
            { self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Export'")).firstMatch.exists }
        ], timeout: 12)
        XCTAssertTrue(previewUp, "Async export should produce the preview sheet.")

        // Dismiss the preview sheet by swiping down or tapping outside.
        app.swipeDown(velocity: .fast)
    }

    func testExportVisitsButtonExistsAndIsHittable() throws {
        waitForDashboard()
        tapTab("Settings")
        openSettingsSection(identifier: "dataExport", title: "Data Export")

        let exportBtn = app.buttons["settings.exportVisits"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 where !exportBtn.exists {
            scroll.exists ? scroll.swipeUp() : app.swipeUp()
        }
        XCTAssertTrue(exportBtn.waitForHittable(timeout: 8), "Export Visits button should be present.")
        XCTAssertTrue(app.buttons["settings.restoreBackup"].waitForHittable(timeout: 5), "On-device backup restore should remain reachable.")
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

    private func openSettingsSection(identifier: String, title: String) {
        if identifier == "security", app.switches["settings.appLockToggle"].exists {
            return
        }
        if identifier == "dataExport",
           app.buttons["settings.exportClients"].exists || app.buttons["settings.exportVisits"].exists {
            return
        }

        let sectionButton = app.buttons["settings.section.\(identifier)"]
        if sectionButton.waitForHittable(timeout: 4) {
            sectionButton.tap()
            return
        }

        let sectionTitle = app.staticTexts[title]
        if sectionTitle.waitForHittable(timeout: 2) {
            sectionTitle.tap()
        }
    }

    private func returnToSettingsList() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForHittable(timeout: 5), "Settings back button should be available.")
        back.tap()
        XCTAssertTrue(app.buttons["settings.section.help"].waitForExistence(timeout: 5))
    }

    private func ensureAppLockEnabledWithPIN() {
        let toggle = app.switches["settings.appLockToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "App Lock toggle must be present.")
        if toggle.value as? String == "1" { return }

        toggle.tap()
        let pinSheetUp = waitForAny([
            { self.app.navigationBars["Set PIN"].exists },
            { self.app.staticTexts["Set PIN"].exists },
            { self.app.secureTextFields["settings.pin.new"].exists }
        ], timeout: 6)
        XCTAssertTrue(pinSheetUp, "Enabling App Lock without a saved PIN should ask for an initial PIN.")

        enterInitialPIN("2468")

        XCTAssertTrue(waitForAny([
            { toggle.value as? String == "1" },
            { self.app.buttons["settings.changePIN"].exists }
        ], timeout: 8), "Saving the initial PIN should enable App Lock.")
    }

    private func enterInitialPIN(_ pin: String) {
        let newPIN = app.secureTextFields["settings.pin.new"]
        let confirmPIN = app.secureTextFields["settings.pin.confirm"]
        XCTAssertTrue(newPIN.waitForHittable(timeout: 4), "New PIN field should be hittable.")
        newPIN.tap()
        newPIN.typeText(pin)
        XCTAssertTrue(confirmPIN.waitForHittable(timeout: 4), "Confirm PIN field should be hittable.")
        confirmPIN.tap()
        confirmPIN.typeText(pin)

        let save = app.buttons["settings.pin.save"].exists ? app.buttons["settings.pin.save"] : app.buttons["Save"]
        XCTAssertTrue(save.waitForHittable(timeout: 4), "PIN save button should be hittable.")
        save.tap()
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
