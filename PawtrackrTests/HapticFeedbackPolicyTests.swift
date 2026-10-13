import XCTest
@testable import Pawtrackr

/// Event sequences prove feedback arbitration without requiring a physical actuator.
final class HapticFeedbackPolicyTests: XCTestCase {
    private var policy = HapticFeedbackPolicy()

    /// Feeds controlled eligibility and monotonic timestamps into the arbitration policy.
    private func play(_ event: HapticEvent, at time: TimeInterval,
                      enabled: Bool = true, active: Bool = true,
                      supported: Bool = true, constrained: Bool = false) -> Bool {
        policy.shouldPlay(event, at: time, enabled: enabled, active: active,
                          supported: supported, constrained: constrained)
    }

    func testRapidSelectionChangesCoalesceButLaterChangesRemainResponsive() {
        XCTAssertTrue(play(.selection, at: 1))
        XCTAssertFalse(play(.selection, at: 1.01))
        XCTAssertFalse(play(.selection, at: 1.04))
        XCTAssertTrue(play(.selection, at: 1.06))
    }

    func testButtonAndChipSignalsFromOneTouchDoNotDoubleBuzz() {
        XCTAssertTrue(play(.press, at: 1))
        XCTAssertFalse(play(.selection, at: 1.01))
        XCTAssertTrue(play(.selection, at: 1.06))
    }

    func testConfirmationAndCommittedSuccessAreNotLostBehindATap() {
        XCTAssertTrue(play(.press, at: 1))
        XCTAssertTrue(play(.confirmation, at: 1.01))
        XCTAssertTrue(play(.success, at: 1.02))
        XCTAssertFalse(play(.success, at: 1.03))
    }

    func testDifferentFailureOutcomeCanInterruptSuccessImmediately() {
        XCTAssertTrue(play(.success, at: 1))
        XCTAssertTrue(play(.error, at: 1.01))
        XCTAssertFalse(play(.error, at: 1.02))
        XCTAssertTrue(play(.error, at: 1.62))
    }

    func testIncidentalPressDoesNotCoverAnOutcome() {
        XCTAssertTrue(play(.warning, at: 1))
        XCTAssertFalse(play(.press, at: 1.1))
        XCTAssertTrue(play(.press, at: 1.21))
    }

    func testTurningOffSilencesEveryEventAndResetsTheCooldown() {
        XCTAssertTrue(play(.success, at: 1))
        for event in [HapticEvent.press, .selection, .navigation, .step, .confirmation, .reward, .success, .warning, .error] {
            XCTAssertFalse(play(event, at: 1.01, enabled: false))
        }
        XCTAssertTrue(play(.success, at: 1.02))
    }

    func testBackgroundOrUnsupportedHardwareDoesNotProduceFeedback() {
        XCTAssertFalse(play(.success, at: 1, active: false))
        XCTAssertFalse(play(.error, at: 2, supported: false))
        XCTAssertTrue(play(.success, at: 2.01))
    }

    func testLowPowerOrThermalPressureKeepsOnlyConfirmationAndOutcomes() {
        for event in [HapticEvent.press, .selection, .navigation, .step, .reward] {
            XCTAssertFalse(play(event, at: 1, constrained: true))
        }
        XCTAssertTrue(play(.confirmation, at: 1, constrained: true))
        XCTAssertTrue(play(.success, at: 1.01, constrained: true))
        XCTAssertTrue(play(.warning, at: 1.02, constrained: true))
        XCTAssertTrue(play(.error, at: 1.03, constrained: true))
    }

    func testSuppressedTouchDoesNotDelayTheNextValidInteraction() {
        XCTAssertFalse(play(.selection, at: 1, constrained: true))
        XCTAssertTrue(play(.selection, at: 1.01))
    }

    func testInvalidClockSampleDoesNotPoisonArbitration() {
        XCTAssertFalse(play(.press, at: .nan))
        XCTAssertFalse(play(.press, at: .infinity))
        XCTAssertTrue(play(.press, at: 1))
    }

    func testIntentionalLaterConfirmationIsAccepted() {
        XCTAssertTrue(play(.confirmation, at: 1))
        XCTAssertFalse(play(.confirmation, at: 1.1))
        XCTAssertTrue(play(.confirmation, at: 1.31))
    }
}
