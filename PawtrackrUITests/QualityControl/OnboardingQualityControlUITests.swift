import XCTest

@MainActor
final class OnboardingQualityControlUITests: QualityControlUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launch(onboarding: true)
    }

    func testBackNavigationFromRegionalReturnsToBusiness() throws {
        XCTAssertTrue(app.staticTexts["Welcome to Pawtrackr"].waitForExistence(timeout: 12))
        _ = tapIfHittable(app.buttons["onboarding.continue"], timeout: 5)
        XCTAssertTrue(waitForBusinessProfileStep(), "Welcome should advance to Business Profile.")

        let nameField = app.textFields["onboarding.businessName"]
        XCTAssertTrue(waitUntilHittable(nameField, timeout: 5))
        nameField.tap()
        nameField.typeText("QC Grooming")
        dismissKeyboardIfPresent()

        _ = tapIfHittable(app.buttons["onboarding.continue"], timeout: 4)
        XCTAssertTrue(waitForRegionalStep(), "Regional/contact step should appear.")

        // The keyboard from the name field slides away as the step changes,
        // and the footer moves with it. A tap aimed at Back mid-slide lands
        // where the button was, so wait for the layout to settle.
        _ = waitForAny([{ !self.app.keyboards.firstMatch.exists }], timeout: 4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(tapIfHittable(app.buttons["onboarding.back"], timeout: 4), "Back should be tappable on the contact step.")
        XCTAssertTrue(app.textFields["onboarding.businessName"].waitForExistence(timeout: 5))
    }

    func testPinMismatchBlocksAdvancingToPermissions() throws {
        advanceToSecurityStep()

        let pinField = app.textFields["onboarding.pinField"]
        let confirmField = app.textFields["onboarding.confirmPinField"]

        XCTAssertTrue(pinField.waitForExistence(timeout: 5))
        pinField.tap()
        pinField.typeText("1234")
        confirmField.tap()
        confirmField.typeText("9999")

        XCTAssertTrue(app.staticTexts["PINs do not match."].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Choose Your Defaults"].exists, "Mismatched PINs should block the next step.")
    }

    func testExplorePathDismissesOnboarding() throws {
        advanceToWarmStartStep()

        let explore = app.buttons["onboarding.explore"]
        XCTAssertTrue(waitUntilHittable(explore, timeout: 6))
        explore.tap()

        assertLandedInAppShell("Explore onboarding path should land in the main app shell.")
    }

    func testStartWithRealBusinessPathDismissesOnboarding() throws {
        advanceToWarmStartStep()

        let startReal = app.buttons["onboarding.startReal"]
        XCTAssertTrue(waitUntilHittable(startReal, timeout: 6))
        startReal.tap()

        assertLandedInAppShell("Starting with a real business should land in the main app shell.")
    }

    /// The loyalty step explains automatic points without tiers or a points
    /// simulator, then continues to the finish step.
    func testLoyaltyStepExplainsAutomaticPointsWithoutTiers() throws {
        advanceToLoyaltyStep()

        XCTAssertTrue(app.staticTexts["Check in"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.sliders["onboarding.loyaltySimulator.slider"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["loyaltySimulator.tier"].exists)

        tapOnboardingContinue()
        XCTAssertTrue(waitForAny([
            { self.app.staticTexts["You're all set!"].exists },
            { self.app.buttons["onboarding.explore"].exists }
        ], timeout: 8))
    }

    private func assertLandedInAppShell(_ message: String) {
        let landed = waitForAny([
            { self.app.staticTexts["Dashboard"].exists },
            { self.app.navigationBars["Dashboard"].exists },
            { self.app.staticTexts["Enter PIN"].exists }
        ], timeout: 25)

        XCTAssertTrue(landed, message)
        XCTAssertFalse(app.staticTexts["Welcome to Pawtrackr"].exists)
    }

    /// Setup has no role step: Welcome goes straight to Business Profile.
    private func waitForBusinessProfileStep(timeout: TimeInterval = 5) -> Bool {
        waitForAny([
            { self.app.textFields["onboarding.businessName"].exists },
            {
                let title = self.app.staticTexts["onboarding.stepTitle"]
                return title.exists && title.label == "Business Profile"
            }
        ], timeout: timeout)
    }

    private func advanceToSecurityStep() {
        XCTAssertTrue(app.staticTexts["Welcome to Pawtrackr"].waitForExistence(timeout: 12))
        tapOnboardingContinue()
        XCTAssertTrue(waitForBusinessProfileStep(), "Welcome should advance to Business Profile.")

        let nameField = app.textFields["onboarding.businessName"]
        XCTAssertTrue(waitUntilHittable(nameField, timeout: 5))
        nameField.tap()
        nameField.typeText("QC Grooming")
        dismissKeyboardIfPresent()

        tapOnboardingContinue()
        XCTAssertTrue(waitForRegionalStep(), "Regional/contact step should appear.")
        advanceFromRegionalToSecurity()
    }

    private func waitForRegionalStep(timeout: TimeInterval = 5) -> Bool {
        waitForAny([
            { self.app.staticTexts["Contact Information"].exists },
            { self.app.staticTexts["Regional Info"].exists },
            { self.app.staticTexts["Contact Email"].exists },
            {
                let title = self.app.staticTexts["onboarding.stepTitle"]
                return title.exists && ["Contact Information", "Regional Info"].contains(title.label)
            }
        ], timeout: timeout)
    }

    private func waitForSecurityStep(timeout: TimeInterval = 8) -> Bool {
        waitForAny([
            { self.app.staticTexts["Set Your App PIN"].exists },
            { self.app.staticTexts["Security"].exists },
            { self.app.textFields["onboarding.pinField"].exists }
        ], timeout: timeout)
    }

    private func advanceFromRegionalToSecurity() {
        tapOnboardingContinue()
        if !waitForSecurityStep(timeout: 4), waitForRegionalStep(timeout: 1) {
            tapOnboardingContinue()
        }
        XCTAssertTrue(waitForSecurityStep(), "Regional/contact step should advance to Security.")
    }

    /// Security with a matching PIN, then Permissions, landing on Loyalty.
    private func advanceToLoyaltyStep() {
        advanceToSecurityStep()

        let pinField = app.textFields["onboarding.pinField"]
        let confirmField = app.textFields["onboarding.confirmPinField"]

        pinField.tap()
        pinField.typeText("1234")
        confirmField.tap()
        confirmField.typeText("1234")

        tapOnboardingContinue()
        XCTAssertTrue(app.staticTexts["Choose Your Defaults"].waitForExistence(timeout: 5))
        tapOnboardingContinue()
        XCTAssertTrue(
            app.staticTexts["Rewards without extra math"].waitForExistence(timeout: 8),
            "Permissions should advance to the Loyalty step."
        )
    }

    private func advanceToWarmStartStep() {
        advanceToLoyaltyStep()
        tapOnboardingContinue()
        XCTAssertTrue(waitForAny([
            { self.app.staticTexts["You're all set!"].exists },
            { self.app.staticTexts["Finish"].exists },
            { self.app.buttons["onboarding.explore"].exists }
        ], timeout: 8))
    }

    private func tapOnboardingContinue() {
        let button = app.buttons["onboarding.continue"]
        XCTAssertTrue(waitUntilHittable(button, timeout: 6), "Continue button should be hittable.")
        button.tap()
    }
}
