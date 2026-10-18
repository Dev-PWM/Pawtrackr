//
//  AppRuntime.swift
//  Pawtrackr
//
//  Process-level runtime switches for deterministic test launches.
//

import Foundation

enum AppRuntime {
    static let alternateUITestingArgument = "--uitesting"
    static let uiTestingArgument = "-pawtrackr-ui-testing"
    static let uiTestingEnvironmentKey = "PAWTRACKR_UI_TESTING"
    static let uiTestingStartTabEnvironmentKey = "PAWTRACKR_UI_START_TAB"
    static let uiTestingStartWalkthroughEnvironmentKey = "PAWTRACKR_UI_START_WALKTHROUGH"
    static let uiTestingPremiumEnvironmentKey = "PAWTRACKR_UI_TESTING_PREMIUM"
    static let inMemoryStoreEnvironmentKey = "PAWTRACKR_IN_MEMORY_STORE"
    static let mockStoreKitUnknownArgument = "--mock-storekit-unknown"
    static let mockStoreKitNotEntitledArgument = "--mock-storekit-not-entitled"
    static let mockStoreKitPremiumArgument = "--mock-storekit-premium"

    /// Release switch for keeping the StoreKit subscription code dormant.
    ///
    /// While true, normal app launches do not query StoreKit, do not show the
    /// launch paywall, and treat Pro-gated app surfaces as available. Keep the
    /// code in place so subscriptions can be re-enabled by flipping this to
    /// false when the product is ready to ship.
    static let subscriptionSystemPaused = true

    /// When set, the UI test seeder will skip inserting a BusinessConfig so the
    /// onboarding flow shows on launch — used to drive onboarding XCUI tests.
    static let onboardingTestArgument = "-pawtrackr-ui-onboarding"
    static let firstLaunchTestArgument = "--is-first-launch"

    static var isUITesting: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(uiTestingArgument)
            || processInfo.arguments.contains(alternateUITestingArgument)
            || processInfo.environment[uiTestingEnvironmentKey] == "1"
    }

    /// True when the UI tester wants the onboarding flow to be shown on launch.
    static var isOnboardingTestMode: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(onboardingTestArgument)
            || arguments.contains(firstLaunchTestArgument)
    }

    static var uiTestingStartTab: String? {
        guard isUITesting else { return nil }
        return ProcessInfo.processInfo.environment[uiTestingStartTabEnvironmentKey]?.lowercased()
    }

    #if DEBUG
    /// Opts UI automation into the disposable thousand-client search fixture.
    static var shouldSeedSearchStressFixture: Bool {
        isUITesting && ProcessInfo.processInfo.environment["PAWTRACKR_UI_SEARCH_STRESS"] == "1"
    }
    #endif

    /// True only when a UI test explicitly asks the app shell to launch the
    /// guided walkthrough. Normal UI tests keep the production guard that
    /// prevents onboarding chrome from covering unrelated test screens.
    static var shouldStartWalkthroughForUITesting: Bool {
        guard isUITesting else { return false }
        return ProcessInfo.processInfo.environment[uiTestingStartWalkthroughEnvironmentKey] == "1"
    }

    /// UI-test-only StoreKit override. Production launches always resolve
    /// entitlements through StoreKit.
    static var shouldForcePremiumForUITesting: Bool {
        guard isUITesting else { return false }
        return ProcessInfo.processInfo.environment[uiTestingPremiumEnvironmentKey] == "1"
    }

    static var mockedEntitlementStatusForUITesting: EntitlementStore.Status? {
        guard isUITesting else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(mockStoreKitPremiumArgument) || shouldForcePremiumForUITesting {
            return .entitled(inTrial: true, expiration: .distantFuture)
        }
        if arguments.contains(mockStoreKitNotEntitledArgument) {
            return .notEntitled
        }
        if arguments.contains(mockStoreKitUnknownArgument) {
            return .unknown
        }
        return nil
    }

    /// True when the process was launched by XCTest (unit or UI test). Used by
    /// PawtrackrApp to avoid opening the production disk store
    /// during tests, which otherwise registers a second SwiftData store and can
    /// invalidate model instances created in a test's in-memory container.
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTest") != nil
    }

    /// True when the host app should keep persistence in-memory instead of
    /// opening the production disk store.
    static var prefersInMemoryStore: Bool {
        let env = ProcessInfo.processInfo.environment
        return isUITesting
            || env[inMemoryStoreEnvironmentKey] == "1"
    }

    /// Current UI-test launch scenario (e.g. "empty", "loaded", "error").
    static var currentScenario: Scenario {
        let raw = ProcessInfo.processInfo.environment["PAWTRACKR_SCENARIO"] ?? ""
        return Scenario(rawValue: raw) ?? .default
    }

    enum Scenario: String {
        case `default` = ""
        case empty
        case heavyLoad = "heavy_load"
    }
}
