//
//  LoyaltyUITests.swift
//  PawtrackrUITests
//
//  Focused UI coverage for the premium loyalty gate and rewards catalog.
//

import XCTest

@MainActor
final class LoyaltyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testNonPremiumLoyaltyEntryShowsPaywallAfterDismissedLaunchPaywall() throws {
        launch(entitlement: .notEntitled)
        XCTAssertTrue(app.staticTexts["Elevate Pawtrackr"].waitForExistence(timeout: 8))

        let dismiss = app.buttons["subscriptionPaywall.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 6))
        dismiss.tap()

        openSeededClient()
        tapLoyaltyEntry()

        XCTAssertTrue(app.staticTexts["Elevate Pawtrackr"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["subscriptionPaywall.dismiss"].exists)
    }

    func testKeepingPointsAtFinalReviewAwardsAutomaticallyAndCatalogPreservesBalance() throws {
        launch(entitlement: .premium)
        openSeededClient()

        let checkout = app.buttons["clientDetail.pet.UITest Pet.checkOut"]
        for _ in 0..<6 {
            if checkout.exists && checkout.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(checkout.waitForHittable(timeout: 6))
        checkout.tap()
        // Interrupted UI runs can leave a draft for the deterministic seeded visit.
        let discardDraft = app.buttons["checkout.recovery.discard"]
        if discardDraft.waitForExistence(timeout: 2) { discardDraft.tap() }
        let service = app.buttons["checkout.service.Full Package"]
        XCTAssertTrue(service.waitForHittable(timeout: 8))
        service.tap()
        for _ in 0..<3 {
            let primary = app.buttons["checkout.primaryButton"]
            XCTAssertTrue(primary.waitForHittable(timeout: 8))
            primary.tap()
        }
        XCTAssertTrue(app.buttons["Confirm & Pay"].waitForHittable(timeout: 8))
        let checkoutContent = app.descendants(matching: .any)["checkout.content"].firstMatch
        XCTAssertTrue(checkoutContent.exists)
        XCTAssertTrue(app.buttons["checkout.loyalty.choose"].exists)
        XCTAssertTrue(app.staticTexts["Keep points for later"].exists)
        XCTAssertFalse(app.buttons["clientLoyalty.adjustPoints"].exists)
        app.buttons["Confirm & Pay"].tap()
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))
        app.buttons["checkout.doneButton"].tap()

        tapLoyaltyEntry()
        XCTAssertTrue(app.buttons["clientLoyalty.redeemRewards"].waitForHittable(timeout: 8))
        XCTAssertFalse(app.buttons["clientLoyalty.adjustPoints"].exists)
        XCTAssertTrue(app.staticTexts["115"].waitForExistence(timeout: 8),
                      "The $95 paid visit plus the return bonus earns 115 points automatically.")
        app.buttons["clientLoyalty.redeemRewards"].tap()
        XCTAssertTrue(app.staticTexts["Rewards Catalog"].waitForExistence(timeout: 8))
        let redeem = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "rewardsCatalog.reward.")).firstMatch
        XCTAssertTrue(redeem.waitForHittable(timeout: 6))
        redeem.tap()
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Select this credit on the final checkout review")).firstMatch.waitForExistence(timeout: 8))
        app.alerts.buttons["Done"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["115"].waitForExistence(timeout: 8),
                      "Browsing a credit keeps the points until checkout confirmation.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Visit rewards after automatic earning and redemption"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSelectedCreditAutomaticallyLowersBillAndSavesVisitChoice() throws {
        launch(entitlement: .premium)
        openSeededClient()
        openFinalCheckout()
        app.buttons["Confirm & Pay"].tap()
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))
        app.buttons["checkout.doneButton"].tap()

        let checkIn = app.buttons["clientDetail.pet.UITest Pet.checkIn"]
        scrollTo(checkIn)
        XCTAssertTrue(checkIn.waitForHittable(timeout: 8))
        checkIn.tap()
        let checkout = app.buttons["clientDetail.pet.UITest Pet.checkOut"]
        XCTAssertTrue(checkout.waitForHittable(timeout: 8))
        openFinalCheckout()
        let choose = app.buttons["checkout.loyalty.choose"]
        scrollTo(choose)
        XCTAssertTrue(choose.waitForHittable(timeout: 8))
        choose.tap()
        let select = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checkout.reward.")).firstMatch
        XCTAssertTrue(select.waitForHittable(timeout: 8))
        select.tap()
        XCTAssertTrue(app.staticTexts["$5.00 off this visit"].waitForExistence(timeout: 8))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Final checkout with optional credit reward"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Confirm & Pay"].tap()
        XCTAssertTrue(app.staticTexts["Checkout Complete!"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["$90.00"].exists, "The $5 credit lowers the $95 bill automatically.")
        app.buttons["checkout.doneButton"].tap()
        tapLoyaltyEntry()
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 8),
                      "115 saved − 50 redeemed + 110 earned from the discounted paid visit.")
        XCTAssertTrue(app.staticTexts["Redeemed $5 Visit Credit"].exists)
        let history = XCTAttachment(screenshot: app.screenshot())
        history.name = "Client rewards history after checkout credit"
        history.lifetime = .keepAlways
        add(history)
    }

    private func openFinalCheckout() {
        let checkout = app.buttons["clientDetail.pet.UITest Pet.checkOut"]
        scrollTo(checkout)
        XCTAssertTrue(checkout.waitForHittable(timeout: 8))
        checkout.tap()
        let discardDraft = app.buttons["checkout.recovery.discard"]
        if discardDraft.waitForExistence(timeout: 2) { discardDraft.tap() }
        let service = app.buttons["checkout.service.Full Package"]
        XCTAssertTrue(service.waitForHittable(timeout: 8))
        service.tap()
        for _ in 0..<3 {
            let primary = app.buttons["checkout.primaryButton"]
            XCTAssertTrue(primary.waitForHittable(timeout: 8))
            primary.tap()
        }
        XCTAssertTrue(app.buttons["Confirm & Pay"].waitForHittable(timeout: 8))
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
    }

    private enum EntitlementLaunch {
        case notEntitled
        case premium
    }

    private func launch(entitlement: EntitlementLaunch) {
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "-pawtrackr-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        switch entitlement {
        case .notEntitled:
            app.launchArguments.append("--mock-storekit-not-entitled")
        case .premium:
            app.launchArguments.append("--mock-storekit-premium")
            app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
        }
        app.launch()
    }

    private func openSeededClient() {
        XCTAssertTrue(waitForDashboard(), "Dashboard did not load.")
        tapTab("Clients")

        let row = app.buttons["clients.row.UITest Owner"]
        let staticRow = app.staticTexts["UITest Owner"]

        if row.waitForHittable(timeout: 8) {
            row.tap()
        } else if staticRow.waitForHittable(timeout: 4) {
            staticRow.tap()
        } else {
            XCTFail("Could not find seeded client row.")
        }
    }

    private func tapLoyaltyEntry() {
        let loyaltyEntry = app.descendants(matching: .any)["clientDetail.loyaltyRewards"]
        let labeledEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Loyalty and rewards")).firstMatch
        let scrollView = app.scrollViews.firstMatch

        for _ in 0..<8 {
            if loyaltyEntry.exists && loyaltyEntry.isHittable {
                loyaltyEntry.tap()
                return
            }
            if labeledEntry.exists && labeledEntry.isHittable {
                labeledEntry.tap()
                return
            }
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
        }

        XCTAssertTrue(loyaltyEntry.waitForHittable(timeout: 4) || labeledEntry.waitForHittable(timeout: 4),
                      "Loyalty entry should be hittable on the seeded client detail screen.")
        if loyaltyEntry.exists && loyaltyEntry.isHittable {
            loyaltyEntry.tap()
        } else {
            labeledEntry.tap()
        }
    }

    private func waitForDashboard(timeout: TimeInterval = 12) -> Bool {
        waitForAny([
            { self.app.staticTexts["Dashboard"].exists },
            { self.app.navigationBars["Dashboard"].exists }
        ], timeout: timeout)
    }

    private func tapTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForHittable(timeout: 8), "\(title) tab was not hittable.")
        tab.tap()
    }

    @discardableResult
    private func waitForAny(_ conditions: [() -> Bool], timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if conditions.contains(where: { $0() }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return conditions.contains(where: { $0() })
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

private extension XCUIApplication {
    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }
}
