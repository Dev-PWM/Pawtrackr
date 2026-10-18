import XCTest
@testable import Pawtrackr

final class AvatarIdentityTests: XCTestCase {
    func testClientInitialsFollowTheSelectedNameOrder() {
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "Ava", lastName: "Martinez", lastNameFirst: false), "AM")
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "Ava", lastName: "Martinez", lastNameFirst: true), "MA")
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "Jordan", lastName: "Lee", lastNameFirst: true), "LJ")
    }

    func testCompoundNamesUseOneInitialPerFieldAndPreserveUnicode() {
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "Mary Ann", lastName: "de la Cruz", lastNameFirst: false), "MD")
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "Mary Ann", lastName: "de la Cruz", lastNameFirst: true), "DM")
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "José", lastName: "Núñez", lastNameFirst: true), "NJ")
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "👩🏽‍🔬", lastName: "Scientist", lastNameFirst: true), "S👩🏽‍🔬")
        XCTAssertEqual(IconCircle.makeClientInitials(firstName: "Ava", lastName: "  ", lastNameFirst: true), "A")
        XCTAssertNil(IconCircle.makeClientInitials(firstName: " ", lastName: " ", lastNameFirst: true))
    }

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
