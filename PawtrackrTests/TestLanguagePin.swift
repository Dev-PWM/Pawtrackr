//
//  TestLanguagePin.swift
//  PawtrackrTests
//
//  The unit tests run inside the app, so they inherit the app language saved
//  on the simulator. Every user-facing string goes through AppLocalization,
//  which honours that setting, so a simulator left in Spanish would turn
//  English assertions red. Each test starts in English; a test that needs
//  Spanish sets it itself. The saved setting comes back when the run ends.
//

import Foundation
import XCTest
@testable import Pawtrackr

/// The test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass`).
final class TestLanguagePin: NSObject, XCTestObservation {
    private var savedLanguage: String?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        savedLanguage = UserDefaults.standard.string(forKey: AppSettingsKeys.appLanguageOverride)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        UserDefaults.standard.set(AppLanguageOverride.en.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: AppSettingsKeys.appLanguageOverride)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride)
        }
    }
}
