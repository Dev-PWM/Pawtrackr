//
//  AppSettings.swift
//  Pawtrackr
//
//  User preferences and security settings.
//

import SwiftUI
import Observation

/// Keys used for UserDefaults persistence.
/// Internal visibility ensures accessibility for Observation macro expansion across platforms.
enum AppSettingsKeys {
    static let isLockEnabled = "isLockEnabled"
    static let isBiometricLockEnabled = "isBiometricLockEnabled"
    /// Legacy UserDefaults key — kept only so we can migrate any existing
    /// plaintext PIN out of UserDefaults and into the Keychain on launch,
    /// then erase it. New writes should never set this key.
    static let legacyAppPIN = "appPIN"
    /// Keychain account name for the current PIN.
    static let appPINKeychainAccount = "appPIN"
    static let lastPINChangeDate = "lastPINChangeDate"
    static let autoLockOnBackground = "autoLockOnBackground"
    static let autoLockAfterInactivity = "autoLockAfterInactivity"
    static let businessName = "businessName"
    static let currencySymbol = "currencySymbol"
    static let isChecklistDismissed = "isChecklistDismissed"
    static let hasSeenAppTour = "hasSeenAppTour"
    /// Set once the user goes through the whole Academy to its last stop.
    static let hasCompletedAcademy = "hasCompletedFullAcademy"
    static let preferredColorScheme = "preferredColorScheme"
    static let hapticsEnabled = "hapticsEnabled"
    static let brandColorHex = "brandColorHex"
    static let defaultLaunchTab = "defaultLaunchTab"
    static let appLanguageOverride = "appLanguageOverride"
    static let optimizeMediaForStorage = LocalMediaPolicy.optimizedMediaDefaultsKey
    static let idleLockMinutes = "idleLockMinutes"
    static let onboardingRole = "onboardingRole"
    /// Guided tour progress, per device: finished lesson raw values, and the
    /// stable ID of the last stop moved past.
    static let tourCompletedLessons = "tourCompletedLessons"
    static let tourLastCompletedStepID = "tourLastCompletedStepID"
}

/// User-selected app language. `system` defers to the device language.
enum AppLanguageOverride: String, CaseIterable, Identifiable {
    case system, en, es

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return AppLocalization.localized("settings.language.system", value: "System Default")
        case .en:
            return AppLocalization.localized("settings.language.english", value: "English")
        case .es:
            return AppLocalization.localized("settings.language.spanish", value: "Español")
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .en: return Locale(identifier: "en")
        case .es: return Locale(identifier: "es-419")
        }
    }

    var preferredLprojNames: [String] {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
            return preferred.lowercased().hasPrefix("es") ? ["es-419", "es"] : ["en"]
        case .en:
            return ["en"]
        case .es:
            return ["es-419", "es"]
        }
    }

    var usesSpanish: Bool {
        preferredLprojNames.contains { $0.lowercased().hasPrefix("es") }
    }
}

/// Lets SwiftUI redraw text when the app language changes. `AppLocalization`
/// registers a read on every lookup, so any view body that shows a localized
/// string depends on the language, and `AppSettings` reports the change. The
/// language itself stays in UserDefaults. Safe to touch from any thread.
final class AppLanguageObservation: Observable, @unchecked Sendable {
    static let shared = AppLanguageObservation()
    private let registrar = ObservationRegistrar()
    private var revision = 0

    /// Records that the caller's output depends on the app language.
    func track() {
        registrar.access(self, keyPath: \.revision)
    }

    /// Invalidates every view that showed a localized string.
    func languageDidChange() {
        registrar.withMutation(of: self, keyPath: \.revision) {}
    }
}

enum AppLocalization {
    static var currentLanguageOverride: AppLanguageOverride {
        AppLanguageObservation.shared.track()
        let raw = UserDefaults.standard.string(forKey: AppSettingsKeys.appLanguageOverride)
            ?? AppLanguageOverride.system.rawValue
        return AppLanguageOverride(rawValue: raw) ?? .system
    }

    private static let lprojBundleLock = NSLock()
    nonisolated(unsafe) private static var lprojBundles: [String: Bundle?] = [:]

    /// The app's `<name>.lproj` bundle, looked up once: every visible string
    /// goes through `localized`.
    private static func lprojBundle(named name: String) -> Bundle? {
        lprojBundleLock.lock()
        defer { lprojBundleLock.unlock() }
        if let cached = lprojBundles[name] { return cached }
        let bundle = Bundle.main.url(forResource: name, withExtension: "lproj").flatMap(Bundle.init(url:))
        lprojBundles[name] = bundle
        return bundle
    }

    static var currentLocale: Locale {
        currentLanguageOverride.locale
    }

    static var usesSpanish: Bool {
        currentLanguageOverride.usesSpanish
    }

    /// Returns a localized string using the app language override when one is set.
    static func localized(_ key: String, value: String = "", tableName: String? = nil) -> String {
        let fallback = value.isEmpty ? key : value
        let override = currentLanguageOverride

        guard override != .system else {
            return Bundle.main.localizedString(forKey: key, value: fallback, table: tableName)
        }

        for lprojName in override.preferredLprojNames {
            guard let bundle = lprojBundle(named: lprojName) else { continue }
            let localized = bundle.localizedString(forKey: key, value: nil, table: tableName)
            if localized != key {
                return localized
            }
        }

        return Bundle.main.localizedString(forKey: key, value: fallback, table: tableName)
    }
}

/// User-selectable color scheme preference. `system` defers to the OS.
enum AppColorScheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return AppLocalization.localized("settings.appearance.system", value: "Follow System")
        case .light:  return AppLocalization.localized("settings.appearance.light",  value: "Light")
        case .dark:   return AppLocalization.localized("settings.appearance.dark",   value: "Dark")
        }
    }

    var swiftUIScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    // MARK: - Defaults

    private enum Defaults {
        static let isLockEnabled = true
        /// No shippable default PIN. A compiled-in PIN is, by definition, publicly
        /// known, so the app must never fall back to one (see `init` / `isPINSet`).
        static let pin = ""
        /// UI-test-only seed PIN, applied solely under `AppRuntime.isUITesting` so
        /// the automated lock test has a known code. Never a shipping fallback.
        static let uiTestPIN = "1234"
        static let biometricEnabled = true
        static let autoLockBackground = true
        static let autoLockInactivity = false
        static let idleLockMinutes = 5
        static let businessName = "My Pet Grooming"
        static let currencySymbol = "$"
        static let isChecklistDismissed = false
        static let preferredColorScheme = AppColorScheme.system.rawValue
        static let hapticsEnabled = true
        static let brandColorHex = "#6366F1"
        static let defaultLaunchTab = "dashboard"
        static let appLanguageOverride = AppLanguageOverride.system.rawValue
        static let optimizeMediaForStorage = true
        static let onboardingRole = OnboardingRole.ownerManager.rawValue
    }

    // MARK: - Properties

    /// The dashboard's Getting Started card was closed, or every row was
    /// done. Its rows themselves are read from the store
    /// (`DashboardViewModel.ChecklistFacts`), never from flags.
    var isChecklistDismissed: Bool {
        didSet { UserDefaults.standard.set(isChecklistDismissed, forKey: AppSettingsKeys.isChecklistDismissed) }
    }

    /// True once the new-user feature tour has been seen (or explicitly skipped).
    /// Defaults to `false` so a fresh install gets the tour after onboarding.
    var hasSeenAppTour: Bool {
        didSet { UserDefaults.standard.set(hasSeenAppTour, forKey: AppSettingsKeys.hasSeenAppTour) }
    }

    /// The user finished the whole Academy (not just one chapter). Settings
    /// shows the graduate badge and Re-run Academy. Never reset by Replay.
    var hasCompletedAcademy: Bool {
        didSet { UserDefaults.standard.set(hasCompletedAcademy, forKey: AppSettingsKeys.hasCompletedAcademy) }
    }

    var businessName: String {
        didSet {
            let limited = TextInputLimits.limited(businessName, to: TextInputLimits.name)
            if limited != businessName {
                businessName = limited
            }
            UserDefaults.standard.set(businessName, forKey: AppSettingsKeys.businessName)
        }
    }

    var currencySymbol: String {
        didSet {
            // Sanitize: a blank or whitespace-only symbol would corrupt money
            // formatting everywhere. Trim, cap at 3 chars (covers "$", "kr",
            // "CHF"), and fall back to the default when empty. Re-assigning the
            // property inside its own didSet does not retrigger the observer.
            let trimmed = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty ? Defaults.currencySymbol : String(trimmed.prefix(3))
            if normalized != currencySymbol {
                currencySymbol = normalized
            }
            UserDefaults.standard.set(currencySymbol, forKey: AppSettingsKeys.currencySymbol)
        }
    }

    var isLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLockEnabled, forKey: AppSettingsKeys.isLockEnabled)
            publishSpotlightPolicy()
        }
    }

    var isBiometricLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBiometricLockEnabled, forKey: AppSettingsKeys.isBiometricLockEnabled)
        }
    }

    /// 4-digit App PIN. Validated to ensure it's exactly 4 digits.
    /// Backed by the Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    /// instead of UserDefaults, so it's not in plaintext device backups.
    private(set) var appPIN: String {
        didSet {
            KeychainStorage.set(appPIN, forKey: AppSettingsKeys.appPINKeychainAccount)
            publishSpotlightPolicy()
        }
    }

    var lastPINChangeDate: Date? {
        didSet {
            if let d = lastPINChangeDate {
                UserDefaults.standard.set(d, forKey: AppSettingsKeys.lastPINChangeDate)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettingsKeys.lastPINChangeDate)
            }
        }
    }

    var autoLockOnBackground: Bool {
        didSet {
            UserDefaults.standard.set(autoLockOnBackground, forKey: AppSettingsKeys.autoLockOnBackground)
        }
    }

    var autoLockAfterInactivity: Bool {
        didSet {
            UserDefaults.standard.set(autoLockAfterInactivity, forKey: AppSettingsKeys.autoLockAfterInactivity)
        }
    }

    /// User-selected appearance. The SettingsView surfaces this; ContentView
    /// applies it via `.preferredColorScheme(...)` so the whole tree responds.
    var preferredColorScheme: AppColorScheme {
        didSet {
            UserDefaults.standard.set(preferredColorScheme.rawValue, forKey: AppSettingsKeys.preferredColorScheme)
        }
    }

    /// Global haptics toggle. `HapticManager` reads this on each call so any
    /// view that triggers feedback (buttons, toggles, etc.) is silenced when
    /// disabled — no per-callsite changes required.
    var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: AppSettingsKeys.hapticsEnabled)
        }
    }

    /// Persisted accent color (`#RRGGBB`) for `DS.ColorToken.primary`.
    /// The didSet pushes the value into `ThemeManager` so existing views
    /// using `DS.ColorToken.primary` recolor live without a relaunch.
    var brandColorHex: String {
        didSet {
            UserDefaults.standard.set(brandColorHex, forKey: AppSettingsKeys.brandColorHex)
            ThemeManager.shared.updateBrandColor(hex: brandColorHex)
        }
    }

    /// Which tab to open on cold launch. Stored as the `NavigationItem` raw
    /// value (e.g. "dashboard", "clients", "insights", "settings"). UI tests
    /// override this via `applyUITestLaunchOverrides()`.
    var defaultLaunchTab: String {
        didSet {
            UserDefaults.standard.set(defaultLaunchTab, forKey: AppSettingsKeys.defaultLaunchTab)
        }
    }

    var appLanguageOverride: AppLanguageOverride {
        didSet {
            UserDefaults.standard.set(appLanguageOverride.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
            if appLanguageOverride != oldValue {
                AppLanguageObservation.shared.languageDidChange()
            }
        }
    }

    var optimizeMediaForStorage: Bool {
        didSet {
            UserDefaults.standard.set(optimizeMediaForStorage, forKey: AppSettingsKeys.optimizeMediaForStorage)
        }
    }

    /// Idle threshold (minutes) for auto-lock. Adjustable in Settings and
    /// clamped to a sane 1...60 range so the lock timer can't be disabled by
    /// stuffing in 0 or made effectively infinite.
    var idleLockMinutes: Int {
        didSet {
            let clamped = min(60, max(1, idleLockMinutes))
            if clamped != idleLockMinutes {
                idleLockMinutes = clamped
            }
            UserDefaults.standard.set(idleLockMinutes, forKey: AppSettingsKeys.idleLockMinutes)
        }
    }

    var onboardingRole: OnboardingRole {
        didSet {
            guard onboardingRole != oldValue else { return }
            UserDefaults.standard.set(onboardingRole.rawValue, forKey: AppSettingsKeys.onboardingRole)
        }
    }

    /// How far this device got through the guided tour. Settings reads it for
    /// "Continue Tour (Lesson n of N)" and the lesson list.
    var tourProgress: WalkthroughProgress {
        didSet {
            guard tourProgress != oldValue else { return }
            Self.storeTourProgress(tourProgress)
        }
    }

    // MARK: - Init

    init() {
        if AppRuntime.isUITesting {
            UserDefaults.standard.set(false, forKey: AppSettingsKeys.isLockEnabled)
            UserDefaults.standard.set(false, forKey: AppSettingsKeys.isBiometricLockEnabled)
            UserDefaults.standard.set(false, forKey: AppSettingsKeys.autoLockOnBackground)
            UserDefaults.standard.set(false, forKey: AppSettingsKeys.autoLockAfterInactivity)
            UserDefaults.standard.set(Defaults.currencySymbol, forKey: AppSettingsKeys.currencySymbol)
            UserDefaults.standard.removeObject(forKey: AppSettingsKeys.lastPINChangeDate)
            // UI tests choose the language with -AppleLanguages, which only the
            // System setting follows; a language saved by an earlier run wins
            // over it and turns English assertions Spanish.
            UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride)
            KeychainStorage.remove(forKey: AppSettingsKeys.appPINKeychainAccount)
            KeychainStorage.set(Defaults.uiTestPIN, forKey: AppSettingsKeys.appPINKeychainAccount)
            if AppRuntime.shouldStartWalkthroughForUITesting {
                // A UI test that starts the Academy starts at its first stop,
                // not where an earlier test on this simulator left off.
                UserDefaults.standard.removeObject(forKey: AppSettingsKeys.tourCompletedLessons)
                UserDefaults.standard.removeObject(forKey: AppSettingsKeys.tourLastCompletedStepID)
            }
        }

        // Register defaults first
        // hasSeenAppTour defaults to TRUE so existing installs (which never
        // explicitly set the key) don't suddenly see the tour on update.
        // OnboardingViewModel writes `false` after a fresh setup completes,
        // which is the only path that arms the tour.
        UserDefaults.standard.register(defaults: [
            AppSettingsKeys.isLockEnabled: AppRuntime.isUITesting ? false : Defaults.isLockEnabled,
            AppSettingsKeys.isBiometricLockEnabled: AppRuntime.isUITesting ? false : Defaults.biometricEnabled,
            AppSettingsKeys.autoLockOnBackground: AppRuntime.isUITesting ? false : Defaults.autoLockBackground,
            AppSettingsKeys.autoLockAfterInactivity: AppRuntime.isUITesting ? false : Defaults.autoLockInactivity,
            AppSettingsKeys.isChecklistDismissed: Defaults.isChecklistDismissed,
            AppSettingsKeys.hasSeenAppTour: true,
            AppSettingsKeys.preferredColorScheme: Defaults.preferredColorScheme,
            AppSettingsKeys.hapticsEnabled: Defaults.hapticsEnabled,
            AppSettingsKeys.brandColorHex: Defaults.brandColorHex,
            AppSettingsKeys.defaultLaunchTab: Defaults.defaultLaunchTab,
            AppSettingsKeys.appLanguageOverride: Defaults.appLanguageOverride,
            AppSettingsKeys.optimizeMediaForStorage: Defaults.optimizeMediaForStorage,
            AppSettingsKeys.idleLockMinutes: Defaults.idleLockMinutes,
            AppSettingsKeys.onboardingRole: Defaults.onboardingRole
        ])

        // Read values
        self.businessName = TextInputLimits.limited(
            UserDefaults.standard.string(forKey: AppSettingsKeys.businessName) ?? Defaults.businessName,
            to: TextInputLimits.name
        )
        // didSet sanitization does not run during init, so normalize here too.
        let storedCurrency = (UserDefaults.standard.string(forKey: AppSettingsKeys.currencySymbol) ?? Defaults.currencySymbol)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.currencySymbol = storedCurrency.isEmpty ? Defaults.currencySymbol : String(storedCurrency.prefix(3))
        let storedIdle = UserDefaults.standard.integer(forKey: AppSettingsKeys.idleLockMinutes)
        self.idleLockMinutes = storedIdle == 0 ? Defaults.idleLockMinutes : min(60, max(1, storedIdle))
        self.isLockEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.isLockEnabled)
        self.isBiometricLockEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.isBiometricLockEnabled)
        self.autoLockOnBackground = UserDefaults.standard.bool(forKey: AppSettingsKeys.autoLockOnBackground)
        self.autoLockAfterInactivity = UserDefaults.standard.bool(forKey: AppSettingsKeys.autoLockAfterInactivity)
        self.lastPINChangeDate = UserDefaults.standard.object(forKey: AppSettingsKeys.lastPINChangeDate) as? Date

        self.isChecklistDismissed = UserDefaults.standard.bool(forKey: AppSettingsKeys.isChecklistDismissed)
        self.hasSeenAppTour = UserDefaults.standard.bool(forKey: AppSettingsKeys.hasSeenAppTour)
        self.hasCompletedAcademy = UserDefaults.standard.bool(forKey: AppSettingsKeys.hasCompletedAcademy)

        let storedSchemeRaw = UserDefaults.standard.string(forKey: AppSettingsKeys.preferredColorScheme) ?? Defaults.preferredColorScheme
        self.preferredColorScheme = AppColorScheme(rawValue: storedSchemeRaw) ?? .system
        self.hapticsEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.hapticsEnabled)
        self.brandColorHex = UserDefaults.standard.string(forKey: AppSettingsKeys.brandColorHex) ?? Defaults.brandColorHex
        self.defaultLaunchTab = UserDefaults.standard.string(forKey: AppSettingsKeys.defaultLaunchTab) ?? Defaults.defaultLaunchTab
        let storedLanguageRaw = UserDefaults.standard.string(forKey: AppSettingsKeys.appLanguageOverride) ?? Defaults.appLanguageOverride
        self.appLanguageOverride = AppLanguageOverride(rawValue: storedLanguageRaw) ?? .system
        self.optimizeMediaForStorage = UserDefaults.standard.bool(forKey: AppSettingsKeys.optimizeMediaForStorage)
        let storedOnboardingRole = UserDefaults.standard.string(forKey: AppSettingsKeys.onboardingRole) ?? Defaults.onboardingRole
        self.onboardingRole = OnboardingRole(rawValue: storedOnboardingRole) ?? .ownerManager
        self.tourProgress = Self.loadTourProgress()
        
        // Migrate any existing plaintext PIN out of UserDefaults into the
        // Keychain, then erase the UserDefaults copy. Future reads come from
        // the Keychain only.
        let legacyPIN = UserDefaults.standard.string(forKey: AppSettingsKeys.legacyAppPIN)
        if let legacy = legacyPIN, Self.isValidPIN(legacy),
           KeychainStorage.string(forKey: AppSettingsKeys.appPINKeychainAccount) == nil {
            KeychainStorage.set(legacy, forKey: AppSettingsKeys.appPINKeychainAccount)
        }
        if legacyPIN != nil {
            UserDefaults.standard.removeObject(forKey: AppSettingsKeys.legacyAppPIN)
        }

        // Adopt only a Keychain-stored PIN. There is intentionally NO compiled-in
        // fallback: a shipped default PIN is publicly known, so a device with the
        // lock enabled but no real user PIN must never become unlockable with it.
        // When no valid PIN is stored, `appPIN` stays empty and the lock gate
        // treats the lock as inactive (see `isPINSet`) — no lockout, no guessable
        // code, and no default written into the Keychain.
        let storedPIN = KeychainStorage.string(forKey: AppSettingsKeys.appPINKeychainAccount) ?? ""
        self.appPIN = Self.isValidPIN(storedPIN) ? storedPIN : ""

        // Apply saved accent color to ThemeManager so views using
        // DS.ColorToken.primary render with it from the first frame.
        ThemeManager.shared.updateBrandColor(hex: brandColorHex)

        // Before any record can be indexed: with App Lock on and a PIN set,
        // this removes Pawtrackr's Spotlight items right away.
        publishSpotlightPolicy()
    }

    /// Tells the Spotlight indexer whether it may index (see
    /// `SpotlightPrivacyPolicy`). The indexer acts only when the answer
    /// changes: lock on removes every item, lock off rebuilds the index.
    private func publishSpotlightPolicy() {
        SpotlightIndexer.shared.applyPrivacyPolicy(allowsIndexing: spotlightAllowsIndexing)
    }

    // MARK: - PIN Management

    /// Changes the PIN after validating it's exactly 4 digits.
    /// Returns true if the PIN was successfully changed.
    @discardableResult
    func changePIN(to newPIN: String) -> Bool {
        guard Self.isValidPIN(newPIN) else { return false }
        appPIN = newPIN
        lastPINChangeDate = Date()
        return true
    }

    /// Validates the provided PIN against the stored PIN. Always false when no
    /// real PIN is set, so an empty/unset PIN can never be matched.
    func validatePIN(_ pin: String) -> Bool {
        isPINSet && pin == appPIN
    }

    /// True only when a real 4-digit user PIN is stored. The app lock must never
    /// engage without this — otherwise a device with no stored PIN could fall back
    /// to a guessable code. See `PinLockGate`.
    var isPINSet: Bool {
        Self.isValidPIN(appPIN)
    }

    // NOTE: A `resetPINToDefault()` helper used to live here. It was dead code
    // (zero callers) that reset the PIN to the compiled-in default — a value
    // that is, by definition, publicly known. Removed so it can never be wired
    // to a UI control and silently make a device unlockable with the default
    // code. To clear a PIN, disable App Lock (which the Settings flow guards) or
    // set a new one via `changePIN(_:)`.

    /// Re-arms the new-user guidance (feature tour + dashboard getting-started
    /// checklist). Intentionally non-destructive: it does NOT touch the business
    /// configuration, clients, pets, or visits — it only re-shows the helper UI.
    func replayGettingStarted() {
        hasSeenAppTour = false
        isChecklistDismissed = false
    }

    /// Records one stop of the guided tour. Writes only when progress changed.
    func recordTourProgress(_ event: WalkthroughProgressEvent) {
        let updated = tourProgress.recording(event)
        if updated != tourProgress {
            tourProgress = updated
        }
    }

    /// Forgets which lessons were finished, so Continue starts from lesson 1.
    func resetTourProgress() {
        if tourProgress != WalkthroughProgress() {
            tourProgress = WalkthroughProgress()
        }
    }

    static func loadTourProgress(from defaults: UserDefaults = .standard) -> WalkthroughProgress {
        let rawLessons = defaults.stringArray(forKey: AppSettingsKeys.tourCompletedLessons) ?? []
        return WalkthroughProgress(
            completedLessons: Set(rawLessons.compactMap(WalkthroughLesson.init(rawValue:))),
            lastCompletedStepID: defaults.string(forKey: AppSettingsKeys.tourLastCompletedStepID)
        )
    }

    static func storeTourProgress(_ progress: WalkthroughProgress, in defaults: UserDefaults = .standard) {
        if progress.completedLessons.isEmpty {
            defaults.removeObject(forKey: AppSettingsKeys.tourCompletedLessons)
        } else {
            defaults.set(progress.completedLessons.map(\.rawValue).sorted(), forKey: AppSettingsKeys.tourCompletedLessons)
        }
        if let stepID = progress.lastCompletedStepID {
            defaults.set(stepID, forKey: AppSettingsKeys.tourLastCompletedStepID)
        } else {
            defaults.removeObject(forKey: AppSettingsKeys.tourLastCompletedStepID)
        }
    }

    /// Re-arms the dashboard "getting started" checklist for a clean business
    /// after a Start Fresh wipe. Intentionally leaves `hasSeenAppTour` untouched
    /// (the user has already been guided once) and does NOT alter business config,
    /// currency, PIN, or the service catalog. The checklist's rows come from
    /// the store, so showing the card again is all there is to reset.
    func resetForFreshStart() {
        isChecklistDismissed = false
    }

    /// Checks if a PIN is valid (exactly 4 numeric digits).
    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0.isNumber }
    }
}

/// What App Lock actually does on this device.
///
/// `isLockEnabled` lives in UserDefaults, which a device-backup restore or a
/// phone migration brings back, while the PIN is a ThisDeviceOnly Keychain item
/// that doesn't come back. `PinLockGate` leaves the app unlocked without a PIN,
/// so anything that tells the owner "records are protected" must use this, not
/// `isLockEnabled` alone.
enum AppLockProtectionStatus: Equatable, Sendable {
    /// App Lock is off.
    case off
    /// App Lock is on and a PIN is stored on this device.
    case protected(biometric: Bool)
    /// App Lock is on in settings, but this device has no PIN, so the app
    /// opens without one.
    case needsPIN

    static func resolve(isLockEnabled: Bool, isPINSet: Bool, isBiometricLockEnabled: Bool) -> Self {
        guard isLockEnabled else { return .off }
        return isPINSet ? .protected(biometric: isBiometricLockEnabled) : .needsPIN
    }

    var isProtected: Bool {
        if case .protected = self { return true }
        return false
    }
}

extension AppSettings {
    var lockProtectionStatus: AppLockProtectionStatus {
        .resolve(isLockEnabled: isLockEnabled, isPINSet: isPINSet, isBiometricLockEnabled: isBiometricLockEnabled)
    }
}
