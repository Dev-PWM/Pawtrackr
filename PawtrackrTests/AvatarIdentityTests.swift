import XCTest
@testable import Pawtrackr

final class AvatarIdentityTests: XCTestCase {
    func testCanonicalFullNameKeepsBothInitials() {
        XCTAssertEqual(IconCircle.makeInitials(from: "Art Alvarez"), "AA")
        XCTAssertEqual(IconCircle.makeInitials(from: "Jane Doe"), "JD")
        XCTAssertEqual(IconCircle.makeInitials(from: "  Jane\tDoe\n"), "JD")
    }

    func testCombiningMarksAreCleanedWithoutDestroyingEmoji() {
        XCTAssertEqual(IconCircle.makeInitials(from: "A\u{0334}\u{035C}rt Alvarez"), "AA")
        XCTAssertEqual(IconCircle.makeInitials(from: "José Núñez"), "JN")
        XCTAssertEqual(IconCircle.makeInitials(from: "👩🏽‍🔬 Scientist"), "👩🏽‍🔬S")
        XCTAssertEqual(IconCircle.makeInitials(from: "❤️ Care"), "❤️C")
        XCTAssertNil(IconCircle.makeInitials(from: "\n\t  "))
    }
}
