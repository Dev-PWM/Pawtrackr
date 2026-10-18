import XCTest

/// Native presentation checks use only the app's disposable in-memory UI fixtures.
@MainActor
final class CelebrationRewardsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    func testBirthdayGirlCanReplayAndRewardsShowOnlyPoints() {
        launch("girl")
        let banner = celebrationBanner()
        XCTAssertTrue(banner.label.contains("Birthday girl, UITest Pet!"))
        XCTAssertTrue(banner.label.contains("Turning 3 today"))
        banner.tap()
        XCTAssertTrue(banner.exists)
        capture("Birthday girl celebration")
        openRewards()
        let balance = app.descendants(matching: .any)["loyaltyPointsBadge"].firstMatch
        XCTAssertTrue(balance.waitForExistence(timeout: 6))
        XCTAssertTrue(balance.label.contains("20 points"))
        assertNoTiers()
        let progress = app.descendants(matching: .any)["clientLoyalty.animatedProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        XCTAssertEqual(progress.value as? String, "20 of 100 points")
        capture("Points only rewards with animated progress")
    }

    func testBirthdayBoyHasMatchingCopy() {
        launch("boy")
        let banner = celebrationBanner()
        XCTAssertTrue(banner.label.contains("Birthday boy, UITest Pet!"))
        XCTAssertTrue(banner.label.contains("Turning 3 today"))
        capture("Birthday boy celebration")
    }

    func testUnknownBirthdayCelebratesClientAnniversaryWithoutInventingAge() {
        launch("anniversary")
        let banner = celebrationBanner()
        XCTAssertTrue(banner.label.contains("3 years with us!"))
        XCTAssertTrue(banner.label.contains("UITest Owner"))
        XCTAssertFalse(banner.label.contains("birthday"))
        XCTAssertFalse(banner.label.contains("Turning"))
        banner.tap()
        capture("Client anniversary when birthdate is unknown")
    }

    func testUnlockedRewardsKeepFullProgressAndPointsBalance() {
        launch("unlocked")
        openRewards()
        XCTAssertTrue(app.staticTexts["All rewards unlocked"].waitForExistence(timeout: 6))
        let progress = app.descendants(matching: .any)["clientLoyalty.animatedProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 6))
        XCTAssertTrue((progress.value as? String)?.hasPrefix("500 of 500") == true)
        assertNoTiers()
        capture("All rewards available without membership tiers")
    }

    private func launch(_ scenario: String) {
        app = XCUIApplication()
        app.launchArguments = ["-pawtrackr-ui-testing", "--mock-storekit-premium",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_START_TAB"] = "clients"
        app.launchEnvironment["PAWTRACKR_UI_CELEBRATION"] = scenario
        app.launch()
        let row = app.buttons["clients.row.UITest Owner"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        // Tap the name rather than the nested status chip in the card.
        let name = app.staticTexts["Owner UITest"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        name.tap()
        XCTAssertTrue(app.navigationBars["Client Details"].waitForExistence(timeout: 8))
    }

    private func celebrationBanner() -> XCUIElement {
        let banner = app.descendants(matching: .any)["petProfile.birthdayBanner"].firstMatch
        scrollTo(banner)
        XCTAssertTrue(banner.exists && banner.isHittable)
        return banner
    }

    private func openRewards() {
        // The loyalty entry precedes the pet cards; return to it after checking the banner.
        let entry = app.descendants(matching: .any)["clientDetail.loyaltyRewards"].firstMatch
        for _ in 0..<6 {
            if entry.exists && entry.isHittable { break }
            app.scrollViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Loyalty & Rewards"].waitForExistence(timeout: 6))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Rewards accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func assertNoTiers() {
        for tier in ["Bronze", "Silver", "Gold", "Platinum"] { XCTAssertFalse(app.staticTexts[tier].exists) }
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
        if !element.exists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Missing milestone hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            capture("Missing milestone after scrolling")
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
