//
//  DashboardSecondaryUITests.swift
//  PawtrackrUITests
//
//  Drives the Dashboard's secondary surfaces: quick actions, deep-links,
//  scrollable rows. Complements PawtrackrUITests which already covers core flow.
//

import XCTest

@MainActor
final class DashboardSecondaryUITests: XCTestCase {
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

    // MARK: - Quick actions

    func testQuickAction_NewClient_OpensSheet() throws {
        waitForDashboard()

        let action = app.buttons["dashboard.quickAction.newClient"]
        let scroll = app.scrollViews["dashboard.scroll"]
        for _ in 0..<5 where !action.exists {
            scroll.exists ? scroll.swipeUp() : app.swipeUp()
        }

        XCTAssertTrue(action.waitForHittable(timeout: 8), "Quick action New Client button must exist.")
        action.tap()

        XCTAssertTrue(app.textFields["newClient.firstName"].waitForExistence(timeout: 6),
                      "New Client sheet should open from Dashboard quick action.")

        // Cancel out so other tests start clean.
        app.buttons["newClient.cancel"].tap()
    }

    func testQuickAction_CheckOut_ShowsActiveSessionPicker() throws {
        waitForDashboard()

        let action = app.buttons["dashboard.quickAction.checkOut"]
        let scroll = app.scrollViews["dashboard.scroll"]
        for _ in 0..<5 where !(action.exists && action.isHittable) {
            scroll.exists ? scroll.swipeUp() : app.swipeUp()
        }

        XCTAssertTrue(action.waitForHittable(timeout: 8), "Quick action Check Out button must be hittable.")
        action.tap()

        XCTAssertTrue(
            app.buttons["dashboard.checkoutPicker.row.UITest Pet"].waitForExistence(timeout: 8),
            "Quick action Check Out should list the currently active sessions."
        )
        app.buttons["Cancel"].tap()
    }

    func testDashboardProgressKPIsAreReadOnlyCounters() throws {
        waitForDashboard()

        XCTAssertTrue(app.staticTexts["In Progress"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["dashboard.kpi.inProgressSessions"].exists)
        XCTAssertFalse(app.buttons["dashboard.kpi.completedHistory"].exists)
    }

    func testRevenueKPI_NavigatesToInsights() throws {
        waitForDashboard()

        let action = app.buttons["dashboard.kpi.revenueInsights"]
        XCTAssertTrue(action.waitForHittable(timeout: 8), "Revenue KPI Insights button must be hittable.")
        action.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.staticTexts["Revenue"].waitForExistence(timeout: 10),
                      "Revenue KPI should land on Insights screen.")
    }

    // MARK: - Active session row

    func testActiveSessionRowAppearsAndHasCheckoutButton() throws {
        waitForDashboard()

        let scroll = app.scrollViews["dashboard.scroll"]
        let target = scroll.exists ? scroll : app.scrollViews.firstMatch
        var found = false
        for _ in 0..<6 {
            if app.buttons["dashboard.activeSession.checkoutButton"].exists { found = true; break }
            if target.exists { target.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(found, "Active session row's checkout button should be present (seeded data).")
    }

    /// Regression test for the DashboardViewModel reactivity path.
    /// After a checkout completes, the eventBus emits `.checkoutCompleted`,
    /// DashboardViewModel.refresh() runs, and `activeVisits` becomes empty
    /// (the seeded run starts with exactly one active visit). If the
    /// observation task ever holds `self` strongly across the for-await
    /// suspension — as it did before the fix — the VM doesn't refresh and
    /// the active-session row stays visible, freezing the dashboard's view
    /// of state.
    func testActiveSessionDisappearsAfterCheckoutCompletes() throws {
        waitForDashboard()

        // Sanity: the seeded active session row must be present and hittable
        // (not just existing in the accessibility tree). Looping on .exists
        // alone can break out before the row is scrolled into the viewport,
        // and the later waitForHittable then never scrolls on its own.
        let checkoutButton = app.buttons["dashboard.activeSession.checkoutButton"]
        let scroll = app.scrollViews["dashboard.scroll"]
        var found = false
        for _ in 0..<6 {
            if checkoutButton.exists && checkoutButton.isHittable { found = true; break }
            if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(found, "Seeded active session row must exist before checkout.")

        // Complete a minimum-viable checkout: open from active session,
        // skip through the steps with default selections, confirm.
        checkoutButton.tap()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        let bath = app.buttons["checkout.service.Bath"]
        if bath.waitForHittable(timeout: 5) { bath.tap() }

        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")
        enterVisitAmount()
        tapPrimaryButton(named: "Review Checkout")

        XCTAssertTrue(app.buttons["Confirm & Pay"].waitForHittable(timeout: 8))
        tapPrimaryButton(named: "Confirm & Pay")
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))

        let doneButton = app.buttons["checkout.doneButton"]
        if doneButton.waitForHittable(timeout: 5) { doneButton.tap() }

        waitForDashboard()

        // The crucial assertion: the active-session checkout button must be
        // GONE within a reasonable refresh window. Before the fix, the
        // dashboard would not refresh and this would still be present.
        let disappeared = waitForCondition(timeout: 10) {
            !self.app.buttons["dashboard.activeSession.checkoutButton"].exists
        }
        XCTAssertTrue(
            disappeared,
            "Dashboard's active-session row should disappear after the only seeded active visit is checked out. If this fails, the eventBus → DashboardViewModel.refresh path is broken (likely a retain-cycle regression in the AsyncStream observer)."
        )
    }

    /// End-to-end exercise of the check-in button the user reports as broken:
    /// 1) Check out the seeded active session so UITest Pet has no active visit.
    /// 2) Navigate Clients → UITest Owner → tap the pet's Check In button.
    /// 3) Confirm the alert.
    /// 4) Verify a new active visit appears on the dashboard.
    func testCheckInFromClientDetailCreatesActiveVisit() throws {
        waitForDashboard()

        // ---- Step 1: Clear the seeded active visit via checkout ----
        let checkoutButton = app.buttons["dashboard.activeSession.checkoutButton"]
        let scroll = app.scrollViews["dashboard.scroll"]
        var found = false
        for _ in 0..<6 {
            if checkoutButton.exists && checkoutButton.isHittable { found = true; break }
            if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(found, "Seeded active session row should be hittable on launch.")
        checkoutButton.tap()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        let bath = app.buttons["checkout.service.Bath"]
        if bath.waitForHittable(timeout: 5) { bath.tap() }

        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")
        enterVisitAmount()
        tapPrimaryButton(named: "Review Checkout")
        XCTAssertTrue(app.buttons["Confirm & Pay"].waitForHittable(timeout: 8))
        tapPrimaryButton(named: "Confirm & Pay")
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))

        let doneButton = app.buttons["checkout.doneButton"]
        if doneButton.waitForHittable(timeout: 5) { doneButton.tap() }
        waitForDashboard()

        // ---- Step 2: Navigate to Clients → UITest Owner ----
        let clientsTab = app.tabBars.buttons["Clients"]
        XCTAssertTrue(clientsTab.waitForHittable(timeout: 8), "Clients tab should be hittable.")
        clientsTab.tap()

        let row = app.buttons["clients.row.UITest Owner"]
        let staticRow = app.staticTexts["UITest Owner"]
        if row.waitForHittable(timeout: 8) {
            row.tap()
        } else if staticRow.waitForHittable(timeout: 4) {
            staticRow.tap()
        } else {
            XCTFail("Could not find seeded UITest Owner row.")
            return
        }

        // ---- Step 3: Tap Check In on the pet card and confirm ----
        let checkInBtn = app.buttons["clientDetail.pet.UITest Pet.checkIn"]
        let detailScroll = app.scrollViews.firstMatch
        for _ in 0..<5 where !(checkInBtn.exists && checkInBtn.isHittable) {
            if detailScroll.exists { detailScroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(checkInBtn.waitForHittable(timeout: 5),
                      "Check In button on UITest Pet should be hittable after the active visit is cleared.")
        checkInBtn.tap()

        // ---- Step 4: Verify a new active visit exists ----
        // Easiest signal: the Check Out button on the same pet card becomes hittable
        // (the Check In becomes disabled when activeVisit != nil).
        let checkOutBtn = app.buttons["clientDetail.pet.UITest Pet.checkOut"]
        let checkOutAppeared = waitForCondition(timeout: 8) {
            checkOutBtn.exists && checkOutBtn.isHittable
        }
        XCTAssertTrue(
            checkOutAppeared,
            "After tapping Check In, the same pet's Check Out button should become hittable (i.e. activeVisit is now set). If this fails, the check-in is reaching the alert but not actually creating a visit."
        )
    }

    func testClientDetailCheckoutDoesNotRecreateActiveSessionAfterNavigation() throws {
        waitForDashboard()
        clearSeededActiveSessionFromDashboard()
        openUITestOwnerDetail()

        let checkInBtn = app.buttons["clientDetail.pet.UITest Pet.checkIn"]
        scrollUntilHittable(checkInBtn)
        XCTAssertTrue(checkInBtn.waitForHittable(timeout: 5))
        checkInBtn.tap()

        let checkOutBtn = app.buttons["clientDetail.pet.UITest Pet.checkOut"]
        XCTAssertTrue(checkOutBtn.waitForHittable(timeout: 8))
        checkOutBtn.tap()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        let bath = app.buttons["checkout.service.Bath"]
        if bath.waitForHittable(timeout: 5) { bath.tap() }
        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")
        enterVisitAmount()
        tapPrimaryButton(named: "Review Checkout")
        tapPrimaryButton(named: "Confirm & Pay")
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))

        let doneButton = app.buttons["checkout.doneButton"]
        XCTAssertTrue(doneButton.waitForHittable(timeout: 5))
        doneButton.tap()

        tapTab("Insights")
        tapTab("Dashboard")
        waitForDashboard()

        let stayedCheckedOut = waitForCondition(timeout: 10) {
            !self.app.buttons["dashboard.activeSession.checkoutButton"].exists
        }
        XCTAssertTrue(stayedCheckedOut, "A completed client-detail checkout must not recreate an active session after navigating away.")
    }

    /// Service selection never prices a visit; the groomer types the amount,
    /// and Review stays disabled until one is entered.
    private func enterVisitAmount(_ text: String = "40") {
        let amount = app.textFields["checkout.amountField"]
        if !amount.waitForHittable(timeout: 3) {
            for _ in 0..<4 where !amount.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(amount.waitForHittable(timeout: 5), "Checkout amount field was not hittable.")
        amount.tap()
        amount.typeText(text)
        let done = app.buttons["Done"]
        if done.waitForHittable(timeout: 2) { done.tap() }
    }

    private func tapPrimaryButton(named title: String) {
        let titledButton = app.buttons[title]
        if titledButton.waitForHittable(timeout: 8) {
            titledButton.tap()
            return
        }
        let primaryButton = app.buttons["checkout.primaryButton"]
        XCTAssertTrue(primaryButton.waitForHittable(timeout: 8), "\(title) primary button was not hittable.")
        primaryButton.tap()
    }

    private func waitForCondition(timeout: TimeInterval, _ predicate: @escaping () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return predicate()
    }

    private func clearSeededActiveSessionFromDashboard() {
        let checkoutButton = app.buttons["dashboard.activeSession.checkoutButton"]
        scrollUntilHittable(checkoutButton)
        XCTAssertTrue(checkoutButton.waitForHittable(timeout: 5), "Seeded active session row should be hittable on launch.")
        checkoutButton.tap()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        let bath = app.buttons["checkout.service.Bath"]
        if bath.waitForHittable(timeout: 5) { bath.tap() }
        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")
        enterVisitAmount()
        tapPrimaryButton(named: "Review Checkout")
        tapPrimaryButton(named: "Confirm & Pay")
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))

        let doneButton = app.buttons["checkout.doneButton"]
        if doneButton.waitForHittable(timeout: 5) { doneButton.tap() }
        waitForDashboard()
    }

    private func openUITestOwnerDetail() {
        tapTab("Clients")

        let row = app.buttons["clients.row.UITest Owner"]
        let staticRow = app.staticTexts["UITest Owner"]
        if row.waitForHittable(timeout: 8) {
            row.tap()
        } else if staticRow.waitForHittable(timeout: 4) {
            staticRow.tap()
        } else {
            XCTFail("Could not find seeded UITest Owner row.")
        }
    }

    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 6) {
        let scroll = app.scrollViews["dashboard.scroll"].exists ? app.scrollViews["dashboard.scroll"] : app.scrollViews.firstMatch
        for _ in 0..<attempts where !(element.exists && element.isHittable) {
            if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
        }
    }

    private func tapTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForHittable(timeout: 8), "\(title) tab was not hittable.")
        tab.tap()
        _ = app.wait(for: .runningForeground, timeout: 0.5)
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
