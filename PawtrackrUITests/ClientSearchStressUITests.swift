import XCTest

/// Exercises the real Client Center against a disposable book of ordinary people and dogs.
@MainActor
final class ClientSearchStressUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-pawtrackr-ui-testing", "--mock-storekit-premium",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_START_TAB"] = "clients"
        app.launchEnvironment["PAWTRACKR_UI_SEARCH_STRESS"] = "1"
        app.launch()
        XCTAssertTrue(allCount(1000).waitForExistence(timeout: 25), "The entire stress book must appear.")
    }

    override func tearDownWithError() throws { app = nil }

    func testOrdinaryNamesDogsAndPhonesFindClientsBeyondTheFirstPage() throws {
        let ava = app.buttons["clients.row.Ava Martinez"]
        for query in ["Ava Martinez", "Martinez Ava", "Willow Ava Martinez", "2025550018", "+1 (202) 555-0018"] {
            search(query)
            XCTAssertTrue(ava.waitForExistence(timeout: 8), query)
            XCTAssertTrue(app.buttons["All (1)"].waitForExistence(timeout: 8), query)
        }
        for query in ["Zoe Zimmerman", "Zimmerman Zoe", "Toby Zoe Zimmerman", "Zoe Zimmerman Beagle", "2025550999"] {
            search(query)
            XCTAssertTrue(app.buttons["clients.row.Zoe Zimmerman"].waitForExistence(timeout: 8), query)
            XCTAssertTrue(app.buttons["All (1)"].waitForExistence(timeout: 8), query)
        }
        capture("Alphabetic stress book finds Zoe Zimmerman and Toby beyond the first page")
        for (query, count) in [("Luna", 50), ("Milo", 50), ("55509", 100), ("1 (202)", 1000),
                               ("20255509999", 0), ("Zoe Zimmerman Missing", 0), ("", 1000)] {
            search(query)
            XCTAssertTrue(allCount(count).waitForExistence(timeout: 8), query)
        }
    }

    func testCreatingAClientUpdatesTheCurrentSearchAndTheWholeBookWithoutRestarting() throws {
        search("Clara")
        XCTAssertTrue(app.buttons["All (0)"].waitForExistence(timeout: 8))
        app.keyboards.buttons["Search"].tapIfExists()
        let add = app.buttons["clients.fab.addClient"]
        XCTAssertTrue(add.waitForHittable(timeout: 5))
        add.tap()
        let first = app.textFields["newClient.firstName"]
        XCTAssertTrue(first.waitForHittable(timeout: 6))
        first.tap()
        first.typeText("Clara")
        let last = app.textFields["newClient.lastName"]
        last.tap()
        last.typeText("Watson")
        let phone = app.textFields["newClient.phone"]
        phone.tap()
        phone.typeText("2025558000")
        app.keyboards.buttons["Done"].tapIfExists()
        let form = app.scrollViews.containing(.textField, identifier: "newClient.firstName").firstMatch
        XCTAssertTrue(form.exists)
        let dog = app.textFields["newClient.pet.name"]
        scrollTo(dog, in: form)
        XCTAssertTrue(dog.waitForHittable(timeout: 5))
        dog.tap()
        dog.typeText("Pepper")
        app.keyboards.buttons["Done"].tapIfExists()
        app.keyboards.buttons["Next"].tapIfExists()
        let female = app.segmentedControls.buttons["Female"]
        scrollTo(female, in: form)
        XCTAssertTrue(female.waitForHittable(timeout: 5))
        female.tap()
        let create = app.buttons["newClient.create"]
        XCTAssertTrue(create.waitForHittable(timeout: 5))
        create.tap()
        let row = app.buttons["clients.row.Clara Watson"]
        XCTAssertTrue(row.waitForExistence(timeout: 12), "A successful save must update the already-open search.")
        XCTAssertTrue(app.buttons["All (1)"].exists)
        search("Pepper")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "The new dog's owner must be immediately searchable.")
        XCTAssertTrue(app.buttons["All (1)"].exists)
        capture("New client and dog appear in the existing thousand-client directory")
        search("")
        XCTAssertTrue(allCount(1001).waitForExistence(timeout: 8))
    }

    /// Matches the count as SwiftUI displays it under this test's English locale.
    private func allCount(_ count: Int) -> XCUIElement {
        let number = count.formatted(.number.locale(Locale(identifier: "en_US")))
        return app.buttons["All (\(number))"]
    }

    /// Keeps drag gestures inside the form's visible area, above the iPhone number pad.
    private func scrollTo(_ element: XCUIElement, in form: XCUIElement) {
        for _ in 0..<10 {
            let keyboard = app.keyboards.firstMatch
            let navigation = app.navigationBars["New Client"]
            let top = max(form.frame.minY, navigation.exists ? navigation.frame.maxY : form.frame.minY) + 8
            let bottom = min(form.frame.maxY, keyboard.exists ? keyboard.frame.minY : app.frame.maxY) - 8
            if element.exists, element.frame.minY >= top, element.frame.maxY <= bottom, element.isHittable { return }
            let movesDown = element.exists && !element.frame.isEmpty && element.frame.maxY < top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: form.frame.midX, dy: top + (bottom - top) * (movesDown ? 0.2 : 0.8)
            ))
            let end = origin.withOffset(CGVector(
                dx: form.frame.midX, dy: top + (bottom - top) * (movesDown ? 0.8 : 0.2)
            ))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    /// Replaces the native search field without restarting or navigating away from the directory.
    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForHittable(timeout: 8))
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        if !text.isEmpty { field.typeText(text) }
    }

    /// Keeps visual evidence of the real directory in the XCTest result bundle.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Waits for an existing, tappable element rather than treating offscreen content as ready.
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if exists && isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return exists && isHittable
    }

    /// Dismisses an optional keyboard action only when it is available.
    func tapIfExists() { if exists && isHittable { tap() } }
}
