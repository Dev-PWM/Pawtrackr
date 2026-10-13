import XCTest
@testable import Pawtrackr

final class MotionGovernorTests: XCTestCase {
    func testMotionRequiresActiveSceneAndEveryResourcePermission() {
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for reduce in [false, true] {
                for lowPower in [false, true] {
                    for active in [false, true] {
                        XCTAssertEqual(MotionGovernor.shouldAnimate(reduceMotion: reduce,
                            lowPowerMode: lowPower, thermalState: state, sceneIsActive: active),
                            !reduce && !lowPower && active && (state == .nominal || state == .fair))
                    }
                }
            }
        }
    }
}
