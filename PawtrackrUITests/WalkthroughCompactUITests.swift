import XCTest

@MainActor
final class WalkthroughCompactUITests: QualityControlUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
    }

    func testRecentHistoryStepKeepsGuideReadableOnIPhone() throws {
        launch(startWalkthrough: true)

        advanceWalkthroughUntilActiveAnchor("cdHistory", maxTaps: 80)
        assertActiveWalkthroughAnchor("cdHistory")

        let bubble = app.otherElements["walkthrough.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 8), "Recent History walkthrough bubble should be visible.")

        let screen = app.windows.firstMatch.frame
        // The card is as tall as its copy. Its controls sit inside it, so the
        // guide text above them isn't cut off, and nothing but padding sits
        // below them (the card used to stretch to a fixed height, leaving an
        // empty band under Back and Next).
        let primary = app.buttons["walkthrough.primary"]
        let skip = app.buttons["walkthrough.skip"]
        XCTAssertTrue(primary.waitForExistence(timeout: 4) && skip.exists)
        XCTAssertTrue(primary.isHittable, "layout=\(activeWalkthroughLayoutDebug())")
        XCTAssertTrue(bubble.frame.contains(primary.frame), "layout=\(activeWalkthroughLayoutDebug())")
        XCTAssertTrue(bubble.frame.contains(skip.frame), "layout=\(activeWalkthroughLayoutDebug())")
        let lowestControl = max(primary.frame.maxY, skip.frame.maxY)
        XCTAssertLessThanOrEqual(
            bubble.frame.maxY - lowestControl,
            30,
            "The card should end just below its controls. layout=\(activeWalkthroughLayoutDebug())"
        )
        XCTAssertGreaterThanOrEqual(bubble.frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(
            bubble.frame.maxY,
            screen.maxY,
            "The Recent History guide should not be clipped below the iPhone screen. layout=\(activeWalkthroughLayoutDebug())"
        )
    }

    func testNewClientSaveSpotlightTracksTheToolbarButton() throws {
        launch(startWalkthrough: true)
        advanceWalkthroughUntilActiveAnchor("ncSave", maxTaps: 30)
        assertActiveWalkthroughAnchor("ncSave")
        let create = app.buttons["newClient.create"]
        XCTAssertTrue(create.isHittable)
        let layout = activeWalkthroughLayoutDebug()
        let expression = try NSRegularExpression(pattern: "spotlightGlobal=\\[(-?\\d+),(-?\\d+),(\\d+),(\\d+)\\]")
        let match = try XCTUnwrap(expression.firstMatch(in: layout, range: NSRange(layout.startIndex..., in: layout)))
        let values = try (1...4).map { index -> CGFloat in
            let range = try XCTUnwrap(Range(match.range(at: index), in: layout))
            return CGFloat(try XCTUnwrap(Double(layout[range])))
        }
        let spotlight = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        XCTAssertLessThan(abs(spotlight.midX - create.frame.midX), 4, layout)
        XCTAssertLessThan(abs(spotlight.midY - create.frame.midY), 4, layout)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Create button spotlight alignment"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInsightsNavigationAndExportLessonRemainUsable() throws {
        launch(startWalkthrough: true)
        advanceWalkthroughUntilActiveAnchor("insights", maxTaps: 80)
        assertActiveWalkthroughAnchor("insights")
        XCTAssertTrue(app.tabBars.buttons["Insights"].isHittable,
                      "The real Insights tab must be visible before the mission begins.")
        app.tabBars.buttons["Insights"].tap()
        assertActiveWalkthroughAnchor("insRevenue")

        advanceWalkthroughUntilActiveAnchor("setData", maxTaps: 10)
        assertActiveWalkthroughAnchor("setData")
        let title = app.staticTexts["Export your data"]
        XCTAssertTrue(title.exists)
        XCTAssertTrue(title.isHittable, "The lesson title should be readable. layout=\(activeWalkthroughLayoutDebug())")
        let bubble = app.otherElements["walkthrough.bubble"]
        let primary = app.buttons["walkthrough.primary"]
        XCTAssertTrue(primary.isHittable)
        XCTAssertTrue(bubble.frame.contains(primary.frame))
        XCTAssertTrue(bubble.frame.contains(title.frame))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Readable export lesson"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func advanceWalkthroughUntilActiveAnchor(_ anchor: String, maxTaps: Int) {
        let target = app.otherElements["walkthrough.activeAnchor.\(anchor)"]
        for _ in 0..<maxTaps {
            if target.exists { return }

            if app.otherElements["walkthrough.activeAnchor.cdCheckIn"].exists {
                let checkIn = app.buttons["clientDetail.pet.Pepper.checkIn"]
                if tapVisible(checkIn, timeout: 2), target.waitForExistence(timeout: 4) { return }
            }

            if app.otherElements["walkthrough.activeAnchor.cdCheckOut"].exists {
                let checkOut = app.buttons["clientDetail.pet.Milo.checkOut"]
                if tapVisible(checkOut, timeout: 2), target.waitForExistence(timeout: 4) { return }
            }

            if tapWalkthroughPrimary(timeout: 4) {
                if target.waitForExistence(timeout: 3) { return }
                continue
            }

            if target.waitForExistence(timeout: 3) { return }
        }
        XCTFail("Walkthrough did not reach active anchor \(anchor). current=\(currentActiveWalkthroughAnchor() ?? "none") layout=\(activeWalkthroughLayoutDebug())")
    }

    private func tapWalkthroughPrimary(timeout: TimeInterval = 4) -> Bool {
        let primary = app.buttons["walkthrough.primary"].firstMatch
        guard waitUntilHittable(primary, timeout: timeout) else { return false }
        // A sheet can disappear during XCTest's interruption handling. Tap
        // the observed screen point without retaining its outgoing element.
        let frame = primary.frame
        let origin = app.frame.origin
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y)).tap()
        return true
    }

    private func tapVisible(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        if waitUntilHittable(element, timeout: timeout) {
            element.tap()
            return true
        }

        guard element.exists, element.frame.width > 4, element.frame.height > 4 else {
            return false
        }

        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    private func assertActiveWalkthroughAnchor(_ anchor: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(
            app.otherElements["walkthrough.activeAnchor.\(anchor)"].waitForExistence(timeout: timeout),
            "Walkthrough should expose active anchor \(anchor)."
        )
        XCTAssertTrue(
            app.otherElements["walkthrough.bubble"].waitForExistence(timeout: timeout),
            "Walkthrough bubble should be visible for active anchor \(anchor)."
        )
    }

    private func activeWalkthroughLayoutDebug() -> String {
        app.otherElements
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "walkthrough.activeAnchor."))
            .firstMatch
            .value as? String ?? "no layout debug"
    }

    private func currentActiveWalkthroughAnchor() -> String? {
        let element = app.otherElements
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "walkthrough.activeAnchor."))
            .firstMatch
        guard element.exists else { return nil }
        return element.identifier.replacingOccurrences(of: "walkthrough.activeAnchor.", with: "")
    }
}
