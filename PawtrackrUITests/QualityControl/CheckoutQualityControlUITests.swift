import XCTest

@MainActor
final class CheckoutQualityControlUITests: QualityControlUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launch(startTab: "dashboard")
    }

    func testCreditPaymentShowsReferenceValidationImmediately() throws {
        openCheckoutFromDashboard()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        selectVisibleService("Full Package")

        tapPrimaryButton(named: "Continue to Notes")
        XCTAssertTrue(app.staticTexts["Add notes and photos"].waitForExistence(timeout: 8))

        tapPrimaryButton(named: "Continue to Payment")
        XCTAssertTrue(app.staticTexts["Confirm payment"].waitForExistence(timeout: 8))
        enterAmount("40")
        tapPaymentMethod("checkout.payment.creditCard")

        let validation = app.staticTexts["checkout.referenceValidation"]
        _ = tapIfHittable(app.buttons["Done"], timeout: 2)
        scrollCheckoutElementIntoView(validation)
        XCTAssertTrue(validation.waitForExistence(timeout: 5), "Credit payments should require a reference immediately. \(app.debugDescription)")
    }

    func testPaymentMethodSwitchingDoesNotFreezeCheckout() throws {
        openCheckoutFromDashboard()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        selectVisibleService("Full Package")

        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")

        XCTAssertTrue(app.staticTexts["Confirm payment"].waitForExistence(timeout: 8))

        tapPaymentMethod("checkout.payment.creditCard")
        tapPaymentMethod("checkout.payment.cash")
        tapPaymentMethod("checkout.payment.zelle")

        XCTAssertTrue(
            waitForAny([
                { self.app.textFields["checkout.amountField"].exists },
                { self.app.staticTexts["Summary"].exists }
            ], timeout: 5),
            "Checkout payment step should remain interactive after switching methods."
        )
    }

    func testBackNavigationFromPaymentReturnsToNotes() throws {
        openCheckoutFromDashboard()

        XCTAssertTrue(app.staticTexts["Pick the services"].waitForExistence(timeout: 8))
        selectVisibleService("Full Package")

        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")

        XCTAssertTrue(app.staticTexts["Confirm payment"].waitForExistence(timeout: 8))
        enterAmount("85.25")
        _ = tapIfHittable(app.buttons["checkout.backButton"], timeout: 5)

        XCTAssertTrue(app.staticTexts["Add notes and photos"].waitForExistence(timeout: 6))
        _ = tapIfHittable(app.buttons["checkout.backButton"], timeout: 5)
        selectVisibleService("Basic Package")
        tapPrimaryButton(named: "Continue to Notes")
        tapPrimaryButton(named: "Continue to Payment")
        let amount = app.textFields["checkout.amountField"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue((amount.value as? String)?.contains("85.25") == true,
                      "Changing services must preserve the groomer's entered checkout amount.")
    }

    private func enterAmount(_ value: String) {
        let amount = app.textFields["checkout.amountField"]
        scrollCheckoutElementIntoView(amount)
        XCTAssertTrue(waitUntilHittable(amount, timeout: 5), app.debugDescription)
        amount.tap()
        amount.typeText(value)
        _ = tapIfHittable(app.buttons["Done"], timeout: 2)
    }

    private func selectVisibleService(_ name: String) {
        let service = app.buttons["checkout.service.\(name)"]
        scrollCheckoutElementIntoView(service)
        XCTAssertTrue(waitUntilHittable(service, timeout: 5))
        service.tap()
    }

    private func scrollCheckoutElementIntoView(_ element: XCUIElement, towardTop: Bool = false) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            let movesDown = element.exists ? element.frame.midY < scroll.frame.midY : towardTop
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movesDown ? 0.4 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movesDown ? 0.7 : 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    private func tapPaymentMethod(_ identifier: String) {
        let button = app.buttons[identifier]
        _ = tapIfHittable(app.buttons["Done"], timeout: 2)
        scrollCheckoutElementIntoView(button, towardTop: true)
        XCTAssertTrue(waitUntilHittable(button, timeout: 4), "\(identifier) should be hittable. \(app.debugDescription)")
        button.tap()
    }
}
