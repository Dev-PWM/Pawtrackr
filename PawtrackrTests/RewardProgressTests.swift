import XCTest
@testable import Pawtrackr

@MainActor
final class RewardProgressTests: XCTestCase {
    func testProgressClampsPresentationWithoutChangingTheBalance() {
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: 20, target: 100), 0.2, accuracy: 0.0001)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: 100, target: 100), 1)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: 500, target: 100), 1)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: -20, target: 100), 0)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: 20, target: 0), 0)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: 20, target: -100), 0)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: Int.max, target: 100), 1)
        XCTAssertEqual(AnimatedRewardProgressBar.fraction(points: Int.max, target: Int.max), 1)
    }
}
