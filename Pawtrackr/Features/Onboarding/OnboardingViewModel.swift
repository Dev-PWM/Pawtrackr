import Foundation
import Observation
import SwiftData
import OSLog
import SwiftUI

@Observable
@MainActor
final class OnboardingViewModel {
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "Onboarding")
    @ObservationIgnored private let biometrics = BiometricAuthenticator()
    @ObservationIgnored private var hasLoadedInitialState = false

    private var modelContext: ModelContext?
    private var appSettings: AppSettings?

    enum Step: Int, CaseIterable {
        case welcome, businessProfile, regional, security, permissions, loyalty, warmStart
        
        var title: String {
            switch self {
            case .welcome:
                return NSLocalizedString("onboarding.step.welcome", value: "Welcome", comment: "")
            case .businessProfile:
                return NSLocalizedString("onboarding.step.business_profile", value: "Business Profile", comment: "")
            case .regional:
                return NSLocalizedString("onboarding.step.regional", value: "Regional Info", comment: "")
            case .security:
                return NSLocalizedString("onboarding.step.security", value: "Security", comment: "")
            case .permissions:
                return NSLocalizedString("onboarding.step.permissions", value: "Permissions", comment: "")
            case .loyalty:
                return NSLocalizedString("onboarding.step.loyalty", value: "Loyalty Points", comment: "")
            case .warmStart:
                return NSLocalizedString("onboarding.step.finish", value: "Finish", comment: "")
            }
        }
    }

    var currentStep: Step = .welcome
    var name: String = "" {
        didSet {
            if name.count > TextInputLimits.name {
                name = TextInputLimits.limited(name, to: TextInputLimits.name)
            }
            saveDraft()
        }
    }
    var email: String = "" {
        didSet {
            if email.count > TextInputLimits.email {
                email = TextInputLimits.limited(email, to: TextInputLimits.email)
            }
            saveDraft()
        }
    }
    var phone: String = "" {
        didSet {
            if phone.count > TextInputLimits.phone {
                phone = TextInputLimits.limited(phone, to: TextInputLimits.phone)
            }
            saveDraft()
        }
    }
    var address: String = "" {
        didSet {
            if address.count > TextInputLimits.address {
                address = TextInputLimits.limited(address, to: TextInputLimits.address)
            }
            saveDraft()
        }
    }
    var logoData: Data? = nil { didSet { saveDraft() } }
    /// The PIN and its confirmation live only in memory. They are never put
    /// in the draft: that is a plain UserDefaults dictionary, and the real
    /// PIN belongs in the Keychain (`AppSettings.changePIN`).
    var pin: String = "" {
        didSet {
            // Typing a PIN cancels a prior "skip" choice so finish() doesn't
            // silently leave the app passcode-free after the user changed their mind.
            if !pin.isEmpty { pinSkipped = false }
        }
    }
    var confirmPin: String = ""
    /// User chose to set up the app without a PIN (passcode-free). Defaults false so
    /// existing validation/tests still require a matching 4-digit PIN by default.
    var pinSkipped: Bool = false { didSet { saveDraft() } }
    var biometricsEnabled: Bool = false { didSet { saveDraft() } }
    var lockOnBackgroundEnabled: Bool = true { didSet { saveDraft() } }
    var autoLockAfterInactivityEnabled: Bool = false { didSet { saveDraft() } }
    var currentCurrency: String = "$" { didSet { saveDraft() } }
    var isSaving: Bool = false
    var saveError: String?

    /// Clients a backup on this device holds that the store is missing (the
    /// Welcome screen's restore offer). Sample clients are never added then:
    /// the user should restore their own clients instead.
    var restorableClientCount: Int = 0
    /// A business profile was already in the local store when onboarding bound.
    private(set) var foundExistingBusinessConfig = false
    private(set) var existingClientCountAtBind = 0
    /// The sample-data decision the last finish() made. Read by tests.
    private(set) var lastSampleDataDecision: SampleDataSeedPolicy.Decision?
    var currencySymbol: String {
        get { currentCurrency }
        set { currentCurrency = newValue }
    }
    
    private let draftKey = "com.pawtrackr.onboarding.draft"

    /// True while init assigns initial values and restores the draft. SwiftUI
    /// builds a new OnboardingViewModel every time RootView re-renders (the
    /// State's initial value is evaluated on each OnboardingView init), and an
    /// init that wrote UserDefaults re-invalidated RootView's @AppStorage, which
    /// re-rendered RootView: an endless loop that froze onboarding on a blank screen.
    @ObservationIgnored private var isInitializing = true

    /// Draft fields init restored. bindIfNeeded runs afterwards with the real
    /// AppSettings, whose values for these are still the registered defaults
    /// (onboarding writes them only in finish), so it must leave them alone:
    /// preserving the choices made before setup was interrupted.
    @ObservationIgnored private var restoredDraftFields: Set<String> = []

    private func saveDraft() {
        guard !isInitializing else { return }
        let draft: [String: Any] = [
            "name": name, "email": email, "phone": phone, "address": address,
            "pinSkipped": pinSkipped,
            "biometricsEnabled": biometricsEnabled,
            "lockOnBackgroundEnabled": lockOnBackgroundEnabled,
            "autoLockAfterInactivityEnabled": autoLockAfterInactivityEnabled,
            "currency": currentCurrency
        ]
        // Unchanged drafts aren't rewritten: every UserDefaults write invalidates
        // @AppStorage-backed views, so a no-op write is never free.
        if let saved = UserDefaults.standard.dictionary(forKey: draftKey),
           NSDictionary(dictionary: saved).isEqual(to: draft) {
            return
        }
        UserDefaults.standard.set(draft, forKey: draftKey)
    }

    private func loadDraft() {
        guard let draft = UserDefaults.standard.dictionary(forKey: draftKey) else { return }
        name = draft["name"] as? String ?? ""
        email = draft["email"] as? String ?? ""
        phone = draft["phone"] as? String ?? ""
        address = draft["address"] as? String ?? ""
        pinSkipped = draft["pinSkipped"] as? Bool ?? false
        biometricsEnabled = draft["biometricsEnabled"] as? Bool ?? false
        lockOnBackgroundEnabled = draft["lockOnBackgroundEnabled"] as? Bool ?? true
        autoLockAfterInactivityEnabled = draft["autoLockAfterInactivityEnabled"] as? Bool ?? false
        currentCurrency = draft["currency"] as? String ?? "$"
        for key in ["biometricsEnabled", "lockOnBackgroundEnabled", "autoLockAfterInactivityEnabled"] where draft[key] is Bool {
            restoredDraftFields.insert(key)
        }
        if draft["currency"] is String {
            restoredDraftFields.insert("currency")
        }
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    /// Drafts saved by earlier builds held the PIN in plain text. Called from
    /// bindIfNeeded (a .task), never from init, which must not write defaults.
    private func removePINFromStoredDraft() {
        guard var draft = UserDefaults.standard.dictionary(forKey: draftKey),
              draft["pin"] != nil || draft["confirmPin"] != nil
        else { return }
        draft.removeValue(forKey: "pin")
        draft.removeValue(forKey: "confirmPin")
        UserDefaults.standard.set(draft, forKey: draftKey)
    }

    /// What the finish step can offer about sample clients right now. finish()
    /// decides again with fresh local counts before saving.
    var sampleDataAvailability: SampleDataSeedPolicy.Decision {
        SampleDataSeedPolicy.decide(.init(
            userChoseSampleData: true,
            businessConfigExisted: foundExistingBusinessConfig,
            existingClientCount: existingClientCountAtBind,
            existingPetCount: 0,
            restorableClientCount: restorableClientCount
        ))
    }

    // MARK: - Init
    init(modelContext: ModelContext?, appSettings: AppSettings?) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.currentCurrency = appSettings?.currencySymbol ?? "$"
        self.lockOnBackgroundEnabled = appSettings?.autoLockOnBackground ?? true
        self.autoLockAfterInactivityEnabled = appSettings?.autoLockAfterInactivity ?? false
        self.biometricsEnabled = (appSettings?.isBiometricLockEnabled ?? false) && isBiometricsAvailable

        if AppRuntime.isOnboardingTestMode {
            clearDraft()
        } else {
            loadDraft()
        }
        isInitializing = false
    }

    func bindIfNeeded(modelContext: ModelContext, appSettings: AppSettings) {
        self.modelContext = modelContext
        self.appSettings = appSettings

        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true

        if !restoredDraftFields.contains("currency") {
            currentCurrency = appSettings.currencySymbol
        }
        if !restoredDraftFields.contains("lockOnBackgroundEnabled") {
            lockOnBackgroundEnabled = appSettings.autoLockOnBackground
        }
        if !restoredDraftFields.contains("autoLockAfterInactivityEnabled") {
            autoLockAfterInactivityEnabled = appSettings.autoLockAfterInactivity
        }
        if !restoredDraftFields.contains("biometricsEnabled") {
            biometricsEnabled = appSettings.isBiometricLockEnabled && isBiometricsAvailable
        }
        removePINFromStoredDraft()

        do {
            existingClientCountAtBind = try modelContext.fetchCount(FetchDescriptor<Client>())
            var descriptor = FetchDescriptor<BusinessConfig>()
            descriptor.fetchLimit = 1
            if let config = try modelContext.fetch(descriptor).first {
                foundExistingBusinessConfig = true
                if !config.name.trimmed.isEmpty {
                    name = config.name
                }
                email = config.email ?? ""
                phone = config.phone ?? ""
                address = config.address ?? ""
                logoData = config.logoData
            }
        } catch {
            logger.error("Failed to hydrate onboarding state: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Navigation
    func nextStep() {
        guard canGoNext else {
            HapticManager.notify(.error)
            return
        }
        
        TelemetryService.shared.track(event: "onboarding_step_completed", parameters: ["step": currentStep.title])
        
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        HapticManager.impact(.medium)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = next
        }
    }
    
    /// Skips PIN setup entirely: the app will run passcode-free. Clears any
    /// partially-entered PIN and advances past the security step.
    func skipPIN() {
        pin = ""
        confirmPin = ""
        pinSkipped = true
        HapticManager.impact(.light)
        nextStep()
    }

    func previousStep() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        HapticManager.impact(.light)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = prev
        }
    }
    
    func goToStep(_ step: Step) {
        guard step.rawValue < currentStep.rawValue else { return }
        HapticManager.impact(.light)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = step
        }
    }
    
    var canGoNext: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .businessProfile:
            return businessNameValidationMessage == nil
        case .regional:
            return regionalValidationMessage == nil
        case .security:
            if pinSkipped { return true }
            let normalizedPIN = pin.filter(\.isNumber)
            let normalizedConfirm = confirmPin.filter(\.isNumber)
            return AppSettings.isValidPIN(normalizedPIN) && normalizedPIN == normalizedConfirm
        case .permissions, .loyalty:
            return true
        case .warmStart:
            return true
        }
    }

    var primaryActionTitle: String {
        switch currentStep {
        case .welcome:
            return NSLocalizedString("onboarding.action.get_started", value: "Get Started", comment: "")
        case .loyalty:
            return NSLocalizedString("onboarding.action.review_setup", value: "Review Setup", comment: "")
        default:
            return NSLocalizedString("common.continue", value: "Continue", comment: "")
        }
    }

    var currentValidationMessage: String? {
        switch currentStep {
        case .businessProfile:
            return businessNameValidationMessage
        case .regional:
            return regionalValidationMessage
        case .security:
            return securityValidationMessage
        default:
            return nil
        }
    }

    var businessNameValidationMessage: String? {
        name.trimmed.isEmpty
            ? NSLocalizedString("onboarding.validation.business_name", value: "Add your business name to continue.", comment: "")
            : nil
    }

    var regionalValidationMessage: String? {
        let trimmedEmail = email.trimmed
        guard !trimmedEmail.isEmpty else { return nil }
        // Use a more inclusive but standard regex
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPred = NSPredicate(format:"SELF MATCHES %@", emailRegEx)
        return emailPred.evaluate(with: trimmedEmail)
            ? nil
            : NSLocalizedString("onboarding.validation.email", value: "Enter a valid email address (e.g., hello@business.com).", comment: "")
    }

    var securityValidationMessage: String? {
        let normalizedPIN = pin.filter(\.isNumber)
        let normalizedConfirm = confirmPin.filter(\.isNumber)

        if (!pin.isEmpty && normalizedPIN != pin) || (!confirmPin.isEmpty && normalizedConfirm != confirmPin) {
            return NSLocalizedString("onboarding.validation.pin_numbers_only", value: "PIN must use numbers only.", comment: "")
        }
        if !pin.isEmpty && normalizedPIN.count < 4 {
            return NSLocalizedString("onboarding.validation.pin_four_digits", value: "PIN must be 4 digits.", comment: "")
        }
        if !confirmPin.isEmpty && normalizedConfirm.count < 4 {
            return NSLocalizedString("onboarding.validation.confirm_pin", value: "Confirm your 4-digit PIN.", comment: "")
        }
        if normalizedPIN.count == 4 && normalizedConfirm.count == 4 && normalizedPIN != normalizedConfirm {
            return NSLocalizedString("onboarding.validation.pin_mismatch", value: "PINs do not match.", comment: "")
        }
        return nil
    }

    var isBiometricsAvailable: Bool {
        switch biometrics.biometricType() {
        case .faceID, .touchID:
            return true
        case .none, .unavailable:
            return false
        }
    }

    var biometricTitle: String {
        switch biometrics.biometricType() {
        case .faceID:
            return NSLocalizedString("onboarding.biometric.face_id_title", value: "Face ID Unlock", comment: "")
        case .touchID:
            return NSLocalizedString("onboarding.biometric.touch_id_title", value: "Touch ID Unlock", comment: "")
        case .unavailable:
            return NSLocalizedString("onboarding.biometric.unavailable_title", value: "Biometric Unlock (currently unavailable)", comment: "")
        case .none:
            return NSLocalizedString("onboarding.biometric.default_title", value: "Biometric Unlock", comment: "")
        }
    }

    var biometricSubtitle: String {
        switch biometrics.biometricType() {
        case .faceID, .touchID:
            return NSLocalizedString("onboarding.biometric.available_subtitle", value: "Use biometrics alongside your PIN for faster unlock.", comment: "")
        case .unavailable:
            return NSLocalizedString("onboarding.biometric.unavailable_subtitle", value: "Biometrics are temporarily unavailable on this device. Sign in with your PIN.", comment: "")
        case .none:
            return NSLocalizedString("onboarding.biometric.none_subtitle", value: "This device does not have biometric unlock available right now.", comment: "")
        }
    }
    
    // MARK: - Actions

    @MainActor
    @discardableResult
    func finish(seedSampleData: Bool, onComplete: @escaping () -> Void) async -> Task<Void, Never>? {
        guard !isSaving else { return nil }
        isSaving = true
        // Safety net: isSaving is always cleared regardless of which path exits.
        defer { isSaving = false }
        saveError = nil
        await Task.yield()

        logger.info("Starting onboarding finish (seed: \(seedSampleData))")

        guard let context = modelContext else {
            logger.error("Finish failed: modelContext is nil")
            saveError = NSLocalizedString("onboarding.error.internal_context", value: "Internal Error: Database context not found.", comment: "")
            return nil
        }

        guard let settings = appSettings else {
            logger.error("Finish failed: appSettings is nil")
            saveError = NSLocalizedString("onboarding.error.internal_settings", value: "Internal Error: App settings not found.", comment: "")
            return nil
        }

        let businessName = name.trimmed
        let businessEmail = email.trimmed.nilIfEmpty
        let businessPhone = phone.trimmed.nilIfEmpty
        let businessAddress = address.trimmed.nilIfEmpty
        let currentCurrency = currentCurrency
        let currentPIN = pin.filter(\.isNumber)
        let useBiometrics = biometricsEnabled && isBiometricsAvailable

        guard businessNameValidationMessage == nil else {
            saveError = businessNameValidationMessage
            return nil
        }
        guard regionalValidationMessage == nil else {
            saveError = regionalValidationMessage
            return nil
        }
        let pinMatches = AppSettings.isValidPIN(currentPIN) && currentPIN == confirmPin.filter(\.isNumber)
        guard pinSkipped || pinMatches else {
            saveError = NSLocalizedString("onboarding.validation.pin_incomplete", value: "Your PIN is incomplete. Enter the same 4 digits in both fields.", comment: "")
            return nil
        }

        do {
            var descriptor = FetchDescriptor<BusinessConfig>()
            descriptor.fetchLimit = 1
            let existingConfig = try context.fetch(descriptor).first

            // Check existing records before writing the setup profile.
            let decision = SampleDataSeedPolicy.decide(.init(
                userChoseSampleData: seedSampleData,
                businessConfigExisted: existingConfig != nil || foundExistingBusinessConfig,
                existingClientCount: try context.fetchCount(FetchDescriptor<Client>()),
                existingPetCount: try context.fetchCount(FetchDescriptor<Pet>()),
                restorableClientCount: restorableClientCount
            ))
            lastSampleDataDecision = decision
            let shouldSeed = decision == .seed
            if seedSampleData, case .skip(let reason) = decision {
                logger.notice("Sample clients not added: \(String(describing: reason), privacy: .public)")
            }

            let config = existingConfig ?? BusinessConfig()
            if config.name != businessName { config.name = businessName }
            if config.email != businessEmail { config.email = businessEmail }
            if config.phone != businessPhone { config.phone = businessPhone }
            if config.address != businessAddress { config.address = businessAddress }
            if config.logoData != logoData { config.logoData = logoData }
            if !config.isSetupComplete { config.isSetupComplete = true }

            if config.modelContext == nil {
                context.insert(config)
            }

            // Persist BusinessConfig so @Query in RootView re-evaluates and
            // can dismiss onboarding. This save is small and fast.
            if context.hasChanges {
                try context.save()
            }

            // Apply settings (and PIN, unless the user opted out) before kicking
            // off background work. When the PIN is skipped the app runs lock-free.
            settings.isLockEnabled = !pinSkipped
            settings.isBiometricLockEnabled = pinSkipped ? false : useBiometrics
            settings.autoLockOnBackground = lockOnBackgroundEnabled
            settings.autoLockAfterInactivity = autoLockAfterInactivityEnabled
            settings.currencySymbol = currentCurrency
            settings.businessName = businessName
            settings.isChecklistDismissed = false
            settings.onboardingRole = .ownerManager

            if !pinSkipped {
                guard settings.changePIN(to: currentPIN) else {
                    throw ValidationError.custom(message: NSLocalizedString("onboarding.error.pin_save_failed", value: "The selected PIN could not be saved.", comment: ""))
                }
            }
            // Note: when pinSkipped, lock is disabled above so the stored PIN is
            // never consulted. Enabling App Lock later in Settings prompts for a PIN.

            // Catalog check and sample clients run in the background so the
            // spinner clears quickly. `ensureServiceCatalog` adds the starter
            // services (no prices) on both paths, so a salon starting for real
            // is never left without a service menu.
            //
            // The tour is armed (hasSeenAppTour = false) only once this has
            // saved: ContentView is already mounted under the onboarding cover
            // and starts the tour as soon as the flag flips, and it decides
            // which steps to show from what the store holds at that moment.
            let container = context.container
            let backgroundTask = Task.detached(priority: .userInitiated) {
                let bg = ModelContext(container)
                DataMigrations.ensureServiceCatalog(in: bg)
                DataMigrations.ensureMessageTemplates(in: bg)
                if shouldSeed {
                    do {
                        try DemoDataSeeder.seedIfNeeded(in: bg)
                    } catch {
                        Logger.database.error("Demo data seed failed during onboarding: \(error.localizedDescription, privacy: .public)")
                    }
                }
                if bg.hasChanges {
                    do {
                        try bg.save()
                    } catch {
                        Logger.database.error("Onboarding catalog save failed: \(error.localizedDescription, privacy: .public)")
                    }
                }

                await MainActor.run {
                    // A new setup starts the tour from its first lesson.
                    settings.resetTourProgress()
                    settings.hasSeenAppTour = false
                    onComplete()
                }
            }

            TelemetryService.shared.track(event: "onboarding_finished", parameters: [
                "seedSampleData": String(seedSampleData),
                "sampleDataAdded": String(shouldSeed)
            ])

            clearDraft()
            Formatters.updateCurrencySymbol(currentCurrency)
            HapticManager.notify(.success)
            
            return backgroundTask
        } catch {
            logger.error("Failed to complete onboarding: \(error.localizedDescription, privacy: .public)")
            saveError = NSLocalizedString("onboarding.error.save_failed", value: "Setup could not be saved. Please try again.", comment: "")
            return nil
        }
    }
}
