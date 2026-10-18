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

    func testAddPetButtonClearsTabBarAndOpensFormInBothAppearances() throws {
        let baselineArguments = app.launchArguments
        for appearance in ["light", "dark"] {
            app.terminate()
            app.launchArguments = baselineArguments + ["-preferredColorScheme", appearance]
            app.launch()
            waitForDashboard()
            guard app.tabBars.firstMatch.exists else {
                throw XCTSkip("This regression covers the compact iPhone action; regular layouts use inline Add Pet.")
            }
            openSeededClient()

            let addPet = app.buttons["clientDetail.addPet.floating"]
            XCTAssertTrue(addPet.waitForHittable(timeout: 6))
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.exists)
            XCTAssertLessThanOrEqual(addPet.frame.maxY + 8, tabBar.frame.minY,
                                     "The add-pet button must remain fully above the tab bar in \(appearance) mode.")

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Client detail add-pet clearance — \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.exists)
            let historyHeading = app.staticTexts["Recent History"]
            XCTAssertTrue(historyHeading.exists)
            let historyPositionBeforeScroll = historyHeading.frame.minY
            scroll.swipeUp()
            XCTAssertLessThan(historyHeading.frame.minY, historyPositionBeforeScroll - 20,
                              "The detail content must actually scroll before checking the floating action again.")
            XCTAssertTrue(addPet.isHittable)
            XCTAssertLessThanOrEqual(addPet.frame.maxY + 8, tabBar.frame.minY)

            addPet.tap()
            let cancel = app.buttons["addPet.cancel"]
            XCTAssertTrue(cancel.waitForHittable(timeout: 6), "Add Pet must open from the floating action.")
            cancel.tap()
            XCTAssertTrue(addPet.waitForHittable(timeout: 6), "Add Pet form must dismiss on cancel.")
        }
    }

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

    func testBehaviorClearanceUpdatesClientWithoutReopeningAndPreservesPriorityCare() throws {
        app.terminate()
        app.launchEnvironment["PAWTRACKR_UI_BEHAVIOR_SCENARIO"] = "aggressive-special-needs"
        app.launch()
        waitForDashboard()
        openSeededClient()
        let aggression = app.descendants(matching: .any)["clientDetail.safetyBanner"].firstMatch
        let care = app.descendants(matching: .any)["clientDetail.specialNeedsBanner"].firstMatch
        XCTAssertTrue(aggression.waitForExistence(timeout: 8))
        XCTAssertTrue(care.exists)
        captureBehaviorScreen("Initial aggression and independent priority care")

        for (index, behavior) in ["calm", "anxious", "nervous"].enumerated() {
            if index > 0 { startNextBehaviorVisit() }
            completeBehaviorCheckout(behavior)
            XCTAssertTrue(care.waitForExistence(timeout: 8), "Care warning must survive every completed visit.")
            if index < 2 {
                XCTAssertTrue(aggression.exists, "Warning must remain for the first two qualifying visits.")
                XCTAssertTrue(aggression.label.contains("\(index + 1)/3"), "Clearance progress must refresh immediately.")
                scrollToBehaviorElement(app.buttons["clientDetail.pet.UITest Pet.history"])
                let badge = app.descendants(matching: .any)["pet.aggression.priorityBadge"].firstMatch
                XCTAssertTrue(badge.label.contains("\(index + 1) of 3"), "Pet badge and client banner must agree.")
                XCTAssertTrue(app.staticTexts["pet.behavior.\(behavior)"].exists, "Today's observation must not disappear during clearance.")
            } else {
                XCTAssertFalse(aggression.exists, "The third mixed qualifying visit must remove aggression without leaving the client.")
                scrollToBehaviorElement(app.buttons["clientDetail.pet.UITest Pet.history"])
                captureBehaviorScreen("Cleared aggression with current nervous observation")
                XCTAssertTrue(app.staticTexts["pet.behavior.nervous"].waitForExistence(timeout: 5))
            }
            captureBehaviorScreen("After \(behavior) checkout \(index + 1)")
            // The original regression appeared only after leaving and reopening
            // the client: cached pre-checkout visits and safety state returned.
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForHittable(timeout: 5))
            back.tap()
            openSeededClient()
            XCTAssertTrue(care.waitForExistence(timeout: 8))
            XCTAssertEqual(aggression.exists, index < 2)
            if index < 2 {
                XCTAssertTrue(aggression.label.contains("\(index + 1)/3"))
            }
            scrollToBehaviorElement(app.buttons["clientDetail.pet.UITest Pet.history"])
            XCTAssertTrue(app.staticTexts["pet.behavior.\(behavior)"].exists)
            XCTAssertFalse(app.staticTexts["Processing"].exists, "Completed visits must not reappear as active history.")
            captureBehaviorScreen("Reopened client after \(behavior)")
        }
        startNextBehaviorVisit()
        completeBehaviorCheckout("aggressive")
        XCTAssertTrue(aggression.waitForExistence(timeout: 8), "An aggressive relapse must restore the warning immediately.")
        XCTAssertFalse(aggression.label.contains("/3"), "Relapse must reset progress.")
        XCTAssertTrue(care.exists)
        captureBehaviorScreen("Aggressive relapse resets progress; care remains")
    }

    func testAnxiousCueInLightAndDarkAppearance() throws {
        let baselineArguments = app.launchArguments
        for appearance in ["Light", "Dark"] {
            app.terminate()
            app.launchArguments = baselineArguments + ["-preferredColorScheme", appearance.lowercased()]
            app.launchEnvironment["PAWTRACKR_UI_BEHAVIOR_SCENARIO"] = "anxious"
            app.launch()
            waitForDashboard()
            openSeededClient()
            scrollToBehaviorElement(app.buttons["clientDetail.pet.UITest Pet.history"])
            XCTAssertTrue(app.staticTexts["pet.behavior.anxious"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["clientDetail.safetyBanner"].firstMatch.exists)
            captureBehaviorScreen("Anxious teal cue — \(appearance)")
        }
    }

    func testBehaviorCardsShowDistinctCuesAndOnlyPriorityWarnings() throws {
        for (behavior, label) in [("calm", "Calm"), ("cooperative", "Cooperative"), ("anxious", "Anxious"), ("nervous", "Nervous"), ("specialNeeds", "Special Needs"), ("aggressive", "Aggressive")] {
            app.terminate()
            app.launchEnvironment["PAWTRACKR_UI_BEHAVIOR_SCENARIO"] = behavior
            app.launch()
            waitForDashboard()
            openSeededClient()
            let aggression = app.descendants(matching: .any)["clientDetail.safetyBanner"].firstMatch
            let care = app.descendants(matching: .any)["clientDetail.specialNeedsBanner"].firstMatch
            XCTAssertTrue(app.staticTexts["UITest Pet"].waitForExistence(timeout: 8))
            XCTAssertEqual(aggression.exists, behavior == "aggressive")
            XCTAssertEqual(care.exists, behavior == "specialNeeds")
            let history = app.buttons["clientDetail.pet.UITest Pet.history"]
            scrollToBehaviorElement(history)
            XCTAssertTrue(history.waitForHittable(timeout: 8), "Glow must not intercept card controls.")
            if behavior != "aggressive" && behavior != "specialNeeds" {
                XCTAssertTrue(app.staticTexts["pet.behavior.\(behavior)"].waitForExistence(timeout: 5), label)
            }
            captureBehaviorScreen("Behavior card — \(behavior)")
            history.tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
        }
    }

    private func startNextBehaviorVisit() {
        let checkIn = app.buttons["clientDetail.pet.UITest Pet.checkIn"]
        scrollToBehaviorElement(checkIn)
        XCTAssertTrue(checkIn.waitForHittable(timeout: 8))
        checkIn.tap()
    }

    private func completeBehaviorCheckout(_ behavior: String) {
        let checkout = app.buttons["clientDetail.pet.UITest Pet.checkOut"]
        scrollToBehaviorElement(checkout)
        XCTAssertTrue(checkout.waitForHittable(timeout: 8))
        checkout.tap()
        let discard = app.buttons["checkout.recovery.discard"]
        if discard.waitForExistence(timeout: 2) { discard.tap() }
        let service = app.buttons["checkout.service.Full Package"]
        XCTAssertTrue(service.waitForHittable(timeout: 8))
        service.tap()
        app.buttons["checkout.primaryButton"].tap()
        waitForCheckoutLayoutToSettle()
        let choice = app.buttons["checkout.behavior.\(behavior)"]
        scrollToBehaviorElement(choice)
        XCTAssertTrue(choice.waitForHittable(timeout: 8))
        choice.tap()
        app.buttons["checkout.primaryButton"].tap()
        // Service selection does not price the visit; the groomer explicitly enters it.
        let amount = app.textFields["checkout.amountField"]
        scrollToBehaviorElement(amount)
        XCTAssertTrue(amount.waitForHittable(timeout: 8))
        amount.tap()
        amount.typeText("40")
        let done = app.buttons["Done"]
        if done.waitForHittable(timeout: 2) { done.tap() }
        app.buttons["checkout.primaryButton"].tap()
        let confirm = app.buttons["Confirm & Pay"]
        XCTAssertTrue(confirm.waitForHittable(timeout: 8))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))
        app.buttons["checkout.doneButton"].tap()
    }

    private func scrollToBehaviorElement(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            let movesDown = element.exists && element.frame.midY < scroll.frame.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movesDown ? 0.4 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movesDown ? 0.7 : 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    private func waitForCheckoutLayoutToSettle() {
        let content = app.descendants(matching: .any)["checkout.content"].firstMatch
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard content.exists else { return false }
            let viewport = self.app.frame
            let frame = content.frame
            // During a slide transition the accessibility union spans both pages.
            return frame.width > 0 && frame.width <= viewport.width + 1
                && frame.minX >= viewport.minX - 1 && frame.maxX <= viewport.maxX + 1
        }, object: content)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                       "Wait for the native page transition before asking for button hit points.")
    }

    private func captureBehaviorScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        let sidebar = app.buttons["sidebar.row.\(title.lowercased())"]
        if sidebar.waitForHittable(timeout: 2) {
            sidebar.tap()
            return
        }
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
