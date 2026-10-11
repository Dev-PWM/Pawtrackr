import XCTest
import UIKit

@MainActor
final class WalkthroughIPadStressUITests: QualityControlUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "iPad walkthrough stress tests require an iPad simulator destination."
        )
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testWalkthroughLaunchFlagStartsTourAndSurvivesIPadRotation() throws {
        launch(startWalkthrough: true)

        XCTAssertTrue(app.otherElements["walkthrough.card"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["walkthrough.stepCounter"].waitForExistence(timeout: 6))
        let initialStepText = app.staticTexts["walkthrough.stepCounter"].label
        XCTAssertFalse(initialStepText.isEmpty, "Step counter should have content")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.otherElements["walkthrough.card"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["walkthrough.stepCounter"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["walkthrough.stepCounter"].label, initialStepText, "Step counter text should persist after portrait rotation")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["walkthrough.card"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["walkthrough.stepCounter"].label, initialStepText, "Step counter text should persist after landscape rotation")
        XCTAssertTrue(waitUntilHittable(app.buttons["walkthrough.primary"], timeout: 6))
    }

    func testWalkthroughBackButtonReturnsToPreviousStepOnIPad() throws {
        launch(startWalkthrough: true)

        // The Academy opens on the app's map, then the dashboard's Today cards.
        assertActiveWalkthroughAnchor("appNavigation", timeout: 15)
        XCTAssertTrue(app.descendants(matching: .any)["practiceSalon.banner"].firstMatch.waitForExistence(timeout: 8), "The Academy runs in the practice salon.")
        XCTAssertTrue(tapWalkthroughPrimary(timeout: 8), "Walkthrough Next should be tappable.")

        assertActiveWalkthroughAnchor("dashKpis", timeout: 10)
        let back = app.buttons["walkthrough.back"]
        XCTAssertTrue(waitUntilHittable(back, timeout: 8), "Walkthrough Back should be tappable.")
        back.tap()

        assertActiveWalkthroughAnchor("appNavigation", timeout: 8)
    }

    func testWalkthroughContinuesToTheNewClientsCardAfterCreatingClient() throws {
        launch(startWalkthrough: true)

        advanceWalkthroughUntilNewClientOwnerForm()

        let firstName = app.textFields["newClient.firstName"]
        XCTAssertTrue(waitUntilHittable(firstName, timeout: 10), "New Client owner form should be visible during the walkthrough.")
        firstName.tap()
        firstName.typeText("Tour")

        let lastName = app.textFields["newClient.lastName"]
        if waitUntilHittable(lastName, timeout: 3) {
            lastName.tap()
            lastName.typeText("Ipad")
        }
        dismissKeyboardIfPresent()

        let create = app.buttons["newClient.create"]
        XCTAssertTrue(waitUntilHittable(create, timeout: 8), "Create should be hittable after the walkthrough has introduced the owner form.")
        create.tap()

        // Created in the practice salon, the new client shows among the cards
        // the next stop points at.
        assertActiveWalkthroughAnchor("clientList", timeout: 12)
        XCTAssertTrue(app.buttons["clients.row.Tour Ipad"].waitForExistence(timeout: 8), "The practice client appears in the list.")
        XCTAssertTrue(waitForAny([
            { self.app.otherElements["walkthrough.card"].exists },
            { self.app.staticTexts["walkthrough.stepCounter"].exists }
        ], timeout: 12), "Walkthrough should continue after creating a client.")
        if app.staticTexts["walkthrough.stepCounter"].exists {
            XCTAssertFalse(app.staticTexts["walkthrough.stepCounter"].label.isEmpty, "Step counter should display progress information")
        }
    }

    func testClientDetailActionTargetsStayHittableAndOpenCheckoutOnIPad() throws {
        launch(startWalkthrough: true)

        advanceWalkthroughUntilActiveAnchor("cdAddPet", maxTaps: 50)
        assertActiveWalkthroughAnchor("cdAddPet")
        XCTAssertTrue(
            waitUntilHittable(app.buttons["clientDetail.addPet.inline"], timeout: 8),
            "The visible iPad Add Pet control should own the Add Pet walkthrough target."
        )

        advanceWalkthroughUntilActiveAnchor("cdCheckOut", maxTaps: 10)
        assertActiveWalkthroughAnchor("cdCheckOut")

        let back = app.buttons["walkthrough.back"]
        XCTAssertTrue(waitUntilHittable(back, timeout: 8), "Back should stay available after check-in completes.")
        back.tap()
        assertActiveWalkthroughAnchor("cdCheckIn")
        XCTAssertTrue(
            waitUntilHittable(app.buttons["walkthrough.primary"], timeout: 8),
            "Completed required-action steps should expose Next when the original highlighted action is no longer available."
        )
        app.buttons["walkthrough.primary"].tap()
        assertActiveWalkthroughAnchor("cdCheckOut")

        // Milo is the practice salon's pet in session.
        let checkoutButton = app.buttons["clientDetail.pet.Milo.checkOut"]
        XCTAssertTrue(checkoutButton.waitForExistence(timeout: 8), "Checkout should be visible for the highlighted walkthrough target.")
        assertBubbleDoesNotCover(checkoutButton, named: "Check Out")
        XCTAssertTrue(
            waitUntilHittable(checkoutButton, timeout: 8),
            "Checkout should be highlighted without the overlay blocking taps. layout=\(activeWalkthroughLayoutDebug())"
        )
        checkoutButton.tap()

        assertActiveWalkthroughAnchor("coServices", timeout: 12)

        advanceWalkthroughUntilActiveAnchor("cdHistory", maxTaps: 6)
        assertActiveWalkthroughAnchor("cdHistory")

        advanceWalkthroughUntilActiveAnchor("cdVisitRow", maxTaps: 3)
        assertActiveWalkthroughAnchor("cdVisitRow")
    }

    func testSettingsWalkthroughDetailTargetsRenderOnIPad() throws {
        launch(startWalkthrough: true)

        advanceWalkthroughUntilActiveAnchor("loyaltySimulator", maxTaps: 64)
        assertActiveWalkthroughAnchor("loyaltySimulator")
        XCTAssertTrue(app.descendants(matching: .any)["loyaltyJourney.card"].exists, "The loyalty stop explains automatic points.")

        advanceWalkthroughUntilActiveAnchor("setData", maxTaps: 3)
        assertActiveWalkthroughAnchor("setData")
        XCTAssertTrue(app.otherElements["walkthrough.bubble"].exists)
    }

    func testSettingsReplayRestartsWalkthroughAfterSkip() throws {
        launch(startWalkthrough: true)

        XCTAssertTrue(waitUntilHittable(app.buttons["walkthrough.skip"], timeout: 15))
        app.buttons["walkthrough.skip"].tap()

        tapSettingsOnIPad()
        openAboutSettingsSection()

        // Skipped on its first stop, so Continue starts the Academy over.
        let continueButton = app.buttons["settings.continueTour"]
        let settingsScroll = app.scrollViews.firstMatch
        for _ in 0..<6 where !continueButton.exists {
            settingsScroll.exists ? settingsScroll.swipeUp() : app.swipeUp()
        }

        XCTAssertTrue(waitUntilHittable(continueButton, timeout: 8), "Continue Academy should be visible in Settings.")
        continueButton.tap()

        XCTAssertTrue(app.otherElements["walkthrough.card"].waitForExistence(timeout: 12))
        let stepCounter = app.staticTexts["walkthrough.stepCounter"]
        XCTAssertTrue(stepCounter.waitForExistence(timeout: 6), "Step counter should appear after replay")
        // The counter reads "Step 1 of N" (WalkthroughOverlay).
        XCTAssertNotNil(
            stepCounter.label.range(of: #"^Step 1 of \d+$"#, options: .regularExpression),
            "Step counter should show step 1 after replay, got \(stepCounter.label)"
        )
        assertActiveWalkthroughAnchor("appNavigation", timeout: 8)
    }

    private func advanceWalkthroughUntilNewClientOwnerForm(maxTaps: Int = 32) {
        let firstName = app.textFields["newClient.firstName"]
        for _ in 0..<maxTaps {
            if firstName.exists { return }

            if tapWalkthroughPrimary(timeout: 4) {
                // Synchronize by waiting for the UI state to change: either the firstName field appears
                // or the next button disappears/changes, avoiding a fixed sleep.
                if firstName.waitForExistence(timeout: 2) { return }
                continue
            }

            if firstName.waitForExistence(timeout: 3) { return }
        }
        XCTFail("Walkthrough did not present the New Client owner form.")
    }

    private func advanceWalkthroughUntilActiveAnchor(_ anchor: String, maxTaps: Int) {
        let target = app.otherElements["walkthrough.activeAnchor.\(anchor)"]
        for _ in 0..<maxTaps {
            if target.exists { return }

            if app.otherElements["walkthrough.activeAnchor.cdCheckIn"].exists {
                let checkIn = app.buttons["clientDetail.pet.Pepper.checkIn"]
                if waitUntilHittable(checkIn, timeout: 2) {
                    checkIn.tap()
                    if target.waitForExistence(timeout: 4) { return }
                }
            }

            if app.otherElements["walkthrough.activeAnchor.cdCheckOut"].exists {
                let checkOut = app.buttons["clientDetail.pet.Milo.checkOut"]
                if waitUntilHittable(checkOut, timeout: 2) {
                    checkOut.tap()
                    if target.waitForExistence(timeout: 4) { return }
                }
            }

            if tapWalkthroughPrimary(timeout: 4) {
                if target.waitForExistence(timeout: 3) { return }
                continue
            }

            if target.waitForExistence(timeout: 3) { return }
        }
        XCTFail("Walkthrough did not reach active anchor \(anchor). current=\(currentActiveWalkthroughAnchor() ?? "none") all=\(allActiveWalkthroughAnchorIdentifiers()) layout=\(activeWalkthroughLayoutDebug())")
    }

    private func tapWalkthroughPrimary(timeout: TimeInterval = 4) -> Bool {
        let primary = app.buttons["walkthrough.primary"]
        if waitUntilHittable(primary, timeout: timeout) {
            primary.tap()
            return true
        }

        guard primary.exists, primary.frame.width > 4, primary.frame.height > 4 else {
            return false
        }

        primary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    private func assertActiveWalkthroughAnchor(_ anchor: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(
            app.otherElements["walkthrough.activeAnchor.\(anchor)"].waitForExistence(timeout: timeout),
            "Walkthrough should expose active anchor \(anchor). current=\(currentActiveWalkthroughAnchor() ?? "none") all=\(allActiveWalkthroughAnchorIdentifiers()) layout=\(activeWalkthroughLayoutDebug())"
        )
        XCTAssertTrue(
            app.otherElements["walkthrough.bubble"].waitForExistence(timeout: timeout),
            "Walkthrough bubble should be visible for active anchor \(anchor)."
        )
    }

    private func activeWalkthroughLayoutDebug() -> String {
        app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "walkthrough.activeAnchor.")).firstMatch.value as? String ?? "no layout debug"
    }

    private func currentActiveWalkthroughAnchor() -> String? {
        let element = app.otherElements
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "walkthrough.activeAnchor."))
            .firstMatch
        guard element.exists else { return nil }
        return element.identifier.replacingOccurrences(of: "walkthrough.activeAnchor.", with: "")
    }

    private func allActiveWalkthroughAnchorIdentifiers() -> [String] {
        app.otherElements
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "walkthrough.activeAnchor."))
            .allElementsBoundByIndex
            .filter(\.exists)
            .map(\.identifier)
    }

    private func assertBubbleDoesNotCover(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bubble = app.otherElements["walkthrough.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 4), "Walkthrough bubble should be visible before checking \(name).", file: file, line: line)
        XCTAssertTrue(element.exists, "\(name) target should exist before checking bubble overlap.", file: file, line: line)
        let debugValue = activeWalkthroughLayoutDebug()
        XCTAssertFalse(
            bubble.frame.intersects(element.frame),
            "Walkthrough bubble should not cover the highlighted \(name) target. bubble=\(bubble.frame) target=\(element.frame) layout=\(debugValue)",
            file: file,
            line: line
        )
    }

    private func tapSettingsOnIPad() {
        let sidebarSettings = app.buttons["sidebar.row.settings"]
        if waitUntilHittable(sidebarSettings, timeout: 6) {
            sidebarSettings.tap()
            return
        }

        let tabSettings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(waitUntilHittable(tabSettings, timeout: 6), "Settings navigation should be available.")
        tabSettings.tap()
    }

    private func openAboutSettingsSection() {
        let about = app.buttons["settings.section.about"]
        let settingsList = app.collectionViews.firstMatch
        for _ in 0..<6 where !about.exists {
            settingsList.exists ? settingsList.swipeUp() : app.swipeUp()
        }

        XCTAssertTrue(waitUntilHittable(about, timeout: 8), "About settings section should be visible.")
        about.tap()
    }
}
