//
//  CheckoutViewModel.swift
//  Pawtrackr
//
//  View-model for CheckoutView: owns selection state, totals math, photos, payment,
//  and visit/payment persistence. Uses modern @Observable and CheckoutTransactionActor.
//

import SwiftUI
import SwiftData
import OSLog
import Combine

 @Observable @MainActor
final class CheckoutViewModel {
    enum CheckoutFlowStep: Int, CaseIterable {
        case services = 0
        case details = 1
        case payment = 2
        case review = 3

        var title: String {
            switch self {
            case .services:
                return NSLocalizedString("checkout.step.services", value: "Services", comment: "")
            case .details:
                return NSLocalizedString("checkout.step.details", value: "Notes & Photos", comment: "")
            case .payment:
                return NSLocalizedString("checkout.step.payment", value: "Payment", comment: "")
            case .review:
                return NSLocalizedString("checkout.step.review", value: "Review", comment: "")
            }
        }

        var primaryButtonTitle: String {
            switch self {
            case .services:
                return NSLocalizedString("checkout.action.continue_notes", value: "Continue to Notes", comment: "")
            case .details:
                return NSLocalizedString("checkout.action.continue_payment", value: "Continue to Payment", comment: "")
            case .payment:
                return NSLocalizedString("checkout.action.review_checkout", value: "Review Checkout", comment: "")
            case .review:
                return NSLocalizedString("checkout.action.confirm_pay", value: "Confirm & Pay", comment: "")
            }
        }
    }

    enum CheckoutState: Equatable {
        case selectingServices
        case addingPhotos
        case choosingPayment
        case processing
        case confirmed
        case failed(AppError)
    }

    struct DraftRecoveryNotice: Equatable {
        let restoredAt: Date
        let missingBeforePhoto: Bool
        let missingAfterPhoto: Bool

        var hasMissingPhotos: Bool {
            missingBeforePhoto || missingAfterPhoto
        }

        var detailText: String {
            let restoredTimestamp = restoredAt.formatted(date: .abbreviated, time: .shortened)
            if missingBeforePhoto && missingAfterPhoto {
                return String.localizedStringWithFormat(
                    NSLocalizedString("checkout.recovery.detail_both_fmt", value: "Recovered your saved checkout from %@. Re-add the before and after photos to finish cleanly.", comment: ""),
                    restoredTimestamp
                )
            }
            if missingBeforePhoto {
                return String.localizedStringWithFormat(
                    NSLocalizedString("checkout.recovery.detail_missing_before_fmt", value: "Recovered your saved checkout from %@. Re-add the before photo to finish cleanly.", comment: ""),
                    restoredTimestamp
                )
            }
            if missingAfterPhoto {
                return String.localizedStringWithFormat(
                    NSLocalizedString("checkout.recovery.detail_missing_after_fmt", value: "Recovered your saved checkout from %@. Re-add the after photo to finish cleanly.", comment: ""),
                    restoredTimestamp
                )
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("checkout.recovery.detail_fmt", value: "Recovered your saved checkout from %@.", comment: ""),
                restoredTimestamp
            )
        }
    }

    // MARK: - Editor Changes
    /// Updates editor-derived state synchronously so critical saves cannot be overtaken.
    private func checkoutStateDidChange(reason: String, immediate: Bool = false) {
        recalculateCachedStrings()
        scheduleDraftSave(reason: reason, immediate: immediate)
    }

    // Dependencies
    private var visitRepository: VisitRepositoryProtocol?
    private var serviceRepository: ServiceRepositoryProtocol?
    private let draftStore: CheckoutDraftStore
    private let eventRecorder: CheckoutEventRecorder
    private var transactionActor: CheckoutTransactionActor?


    // MARK: Models
    var pet: Pet
    var visit: Visit
    var currentStep: CheckoutFlowStep = .services

    // MARK: UI State
    var sessionNotes: String = ""
    var amountString: String = ""
    var selectedServiceIDs: Set<PersistentIdentifier> = [] { didSet { checkoutStateDidChange(reason: "services_changed") } }
    var selectedPaymentMethod: Payment.Method = .cash { didSet { checkoutStateDidChange(reason: "payment_method_changed", immediate: true) } }
    var beforePhotoData: Data? { didSet { checkoutStateDidChange(reason: "before_photo_changed") } }
    var afterPhotoData: Data? { didSet { checkoutStateDidChange(reason: "after_photo_changed") } }
    var externalReference: String = "" { didSet { checkoutStateDidChange(reason: "reference_changed", immediate: true) } }
    var tags: Set<String> = [] { didSet { checkoutStateDidChange(reason: "tags_changed") } }
    var selectedAddOnIDs: Set<PersistentIdentifier> = [] { didSet { checkoutStateDidChange(reason: "addons_changed") } }

    private(set) var completedLoyaltyPoints = 0
    private(set) var loyaltyPoints = 0
    private(set) var loyaltyTier: LoyaltyTier = .bronze
    private(set) var loyaltyRewards: [LoyaltyReward] = []
    private(set) var selectedLoyaltyReward: LoyaltyReward?
    private(set) var loyaltyError: String?
    private(set) var isLoadingLoyalty = false
    var isChoosingLoyaltyReward = false
    private var loyaltyContainer: ModelContainer?
    @ObservationIgnored private var completionContext: ModelContext?

    /// Eligible spa service stays purchasable until a reward is explicitly redeemed.
    var includesSpaPackage: Bool {
        allServices.contains { selectedServiceIDs.contains($0.persistentModelID) && DefaultServiceCatalog.isSpaPackage($0.name) }
    }

    var availableSpaReward: LoyaltyReward? {
        guard !isLoadingLoyalty, loyaltyError == nil else { return nil }
        return loyaltyRewards.first { $0.isSpaPackageReward && $0.isRedeemable(with: loyaltyPoints) }
    }

    var isSpaRedeemed: Bool { selectedLoyaltyReward?.isSpaPackageReward == true && includesSpaPackage }

    var loyaltyCredit: Decimal {
        guard let selectedLoyaltyReward, selectedLoyaltyReward.isApplicable(to: servicesTotalDecimal) else { return .zero }
        return selectedLoyaltyReward.checkoutDiscount(on: servicesTotalDecimal, includesSpa: includesSpaPackage)
    }
    var paymentTotalDecimal: Decimal { max(.zero, servicesTotalDecimal - loyaltyCredit).roundedMoney() }
    var isLoyaltySelectionValid: Bool {
        guard let selectedLoyaltyReward else { return true }
        return !isLoadingLoyalty && loyaltyError == nil && loyaltyPoints >= selectedLoyaltyReward.pointCost
            && (!selectedLoyaltyReward.isSpaPackageReward || includesSpaPackage)
            && selectedLoyaltyReward.isApplicable(to: servicesTotalDecimal)
            && loyaltyRewards.contains { $0.id == selectedLoyaltyReward.id && $0.pointCost == selectedLoyaltyReward.pointCost
                && $0.style == selectedLoyaltyReward.style && $0.checkoutCreditAmount == selectedLoyaltyReward.checkoutCreditAmount }
    }

    /// Refreshes values from a context owned by the loyalty actor.
    func refreshLoyaltyOptions() async {
        guard let loyaltyContainer, let uuid = pet.owner?.uuid, !isLoadingLoyalty else { return }
        isLoadingLoyalty = true
        defer { isLoadingLoyalty = false }
        do {
            let options = try await LoyaltyService(modelContainer: loyaltyContainer).checkoutOptions(clientUUID: uuid)
            loyaltyPoints = options.points
            loyaltyTier = options.tier
            loyaltyRewards = options.rewards
            loyaltyError = nil
        } catch {
            Logger.checkout.error("Checkout rewards refresh failed: \(error.localizedDescription)")
            loyaltyError = AppLocalization.localized("checkout.loyalty.load_error", value: "Unable to load rewards. Keep your points or try again.")
        }
    }

    /// Saves the choice immediately for recovery. The balance changes only with payment.
    func chooseLoyaltyReward(_ reward: LoyaltyReward?) {
        guard !isSaving, state != .confirmed else { return }
        if selectedLoyaltyReward != reward { HapticManager.play(reward == nil ? .selection : .reward) }
        selectedLoyaltyReward = reward
        isChoosingLoyaltyReward = false
        recalculateCachedStrings()
        scheduleCriticalDraftSave(reason: "reward_choice")
    }

    // MARK: State
    private(set) var isSaving: Bool = false
    private(set) var isLoadingServices: Bool = false
    private(set) var draftRecoveryNotice: DraftRecoveryNotice?
    var appError: AppError? = nil
    var state: CheckoutState = .selectingServices

    // MARK: Private State
    var allServices: [Service] = []
    var addOnServices: [Service] = []
    private let checkoutEndsAt: Date?
    private var autosaveTask: Task<Void, Never>?
    private var servicesLoadTask: Task<Void, Never>?
    private var suppressDraftAutosave = false
    private var isBootstrappingCheckout = false
    private var lastAcceptedConfirmAt: Date?
    private let confirmDebounceWindow: TimeInterval = 1.0
    /// True while the guided tour drives this checkout. The tour only shows
    /// the steps: nothing is saved, neither the crash-recovery draft (a tour
    /// jump to Review would otherwise reopen a real visit at Review later) nor
    /// the payment.
    private(set) var isWalkthroughPreview = false

    // MARK: Computed State
    var requiresExternalReference: Bool {
        selectedPaymentMethod.requiresExternalReference && paymentTotalDecimal > .zero
    }

    var referenceFieldTitle: String {
        selectedPaymentMethod.referenceFieldTitle
    }

    var referencePlaceholder: String {
        selectedPaymentMethod.referencePlaceholder
    }

    var referenceHelperText: String {
        selectedPaymentMethod.referenceHelperText
    }

    var referenceValidationMessage: String? {
        selectedPaymentMethod.validationMessage(for: externalReference)
    }

    var isConfirmEnabled: Bool {
        let hasValidAmount = servicesTotalDecimal >= 0 && (servicesTotalDecimal > 0 || isSpaRedeemed)
        let hasValidReference = selectedPaymentMethod.isValidReference(externalReference)
        return hasValidAmount && !isSaving && isLoyaltySelectionValid && (!requiresExternalReference || hasValidReference)
    }

    static let tagOptions: [String] = Pet.BehaviorTag.allCases.map { $0.displayName }

    var sessionDurationString: String {
        let start = visit.startedAt
        let end = visit.endedAt ?? checkoutEndsAt ?? Date()
        return Formatters.durationString(from: start, to: end)
    }

    var sessionEndedAt: Date { visit.endedAt ?? checkoutEndsAt ?? Date() }
    var hasSelectedServices: Bool { !selectedServiceIDs.isEmpty || !selectedAddOnIDs.isEmpty }
    var beforePhotoCount: Int { beforePhotoData == nil ? 0 : 1 }
    var afterPhotoCount: Int { afterPhotoData == nil ? 0 : 1 }
    var totalPhotoCount: Int { beforePhotoCount + afterPhotoCount }
    var paymentMethodLabel: String { selectedPaymentMethod.displayName }
    var paymentReferenceSummary: String {
        let reference = externalReference.trimmed
        return reference.isEmpty ? NSLocalizedString("common.none", value: "None", comment: "") : reference
    }
    var notesPreview: String {
        let trimmed = sessionNotes.trimmed
        return trimmed.isEmpty ? NSLocalizedString("checkout.no_notes_added", value: "No notes added", comment: "") : trimmed
    }
    var behaviorTagsSummary: String {
        let values = tags.sorted()
        return values.isEmpty ? NSLocalizedString("common.none", value: "None", comment: "") : values.joined(separator: ", ")
    }

    // MARK: - Cached Computed Properties
    private(set) var selectedServicesSummary: String = NSLocalizedString("common.none", value: "None", comment: "")
    private(set) var finalTotalString: String = "$0.00"

    private let eventBus: GlobalEventBus

    init(
        pet: Pet,
        visit: Visit,
        draftStore: CheckoutDraftStore = .shared,
        eventRecorder: CheckoutEventRecorder = .shared,
        eventBus: GlobalEventBus = GlobalEventBus()
    ) {
        self.pet = pet
        self.visit = visit
        self.checkoutEndsAt = Date()
        self.draftStore = draftStore
        self.eventRecorder = eventRecorder
        self.eventBus = eventBus

        if visit.behaviorTags.isEmpty {
            let standingTags = pet.behaviorTags.filter { tag in
                Pet.behaviorTagKind(for: tag) == .specialNeeds
            }
            self.tags = Set(standingTags)
        } else {
            self.tags = Set(BehaviorTagIcons.selectedTags(from: visit.behaviorTags))
        }

        // Bind to the real ModelContainer the pet/visit already lives in. Never construct
        // a fallback container — that path would route the entire checkout to an orphan
        // in-memory store and silently lose revenue. If neither object is attached to a
        // container, `loadServices(modelContext:)` will wire one up before checkout runs.
        if let container = pet.modelContext?.container ?? visit.modelContext?.container {
            self.transactionActor = CheckoutTransactionActor(modelContainer: container)
        }
    }

    private static let serviceOrder: [String] = [
        "Full Package", "Basic Package", "Spa Package", "Bath", "Haircut"
    ]

    @MainActor
    func loadServices(modelContext: ModelContext) {
        Logger.checkout.info("CheckoutViewModel: Loading services")
        self.loyaltyContainer = modelContext.container
        self.serviceRepository = ServiceRepository(modelContainer: modelContext.container)
        if self.transactionActor == nil {
            self.transactionActor = CheckoutTransactionActor(modelContainer: modelContext.container)
        }
        isLoadingServices = true

        servicesLoadTask?.cancel()
        servicesLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let serviceRepository = self.serviceRepository else {
                    Logger.checkout.error("CheckoutViewModel: Service repository is nil")
                    self.isLoadingServices = false
                    return
                }
                let all = try await serviceRepository.fetchEnabledServices()
                Logger.checkout.info("CheckoutViewModel: Fetched \(all.count) services")

                let mainServices = all.filter { $0.category != .addOn }
                self.allServices = mainServices.sorted { svc1, svc2 in
                    let idx1 = Self.serviceOrder.firstIndex(of: svc1.name) ?? Int.max
                    let idx2 = Self.serviceOrder.firstIndex(of: svc2.name) ?? Int.max
                    return idx1 != idx2 ? idx1 < idx2 : svc1.name < svc2.name
                }

                self.addOnServices = all.filter { $0.category == .addOn }
                self.isBootstrappingCheckout = true
                self.hydrateStateFromVisit()
                await self.restoreDraftIfAvailable()
                await self.refreshLoyaltyOptions()
                self.isBootstrappingCheckout = false
                self.isLoadingServices = false
                Logger.checkout.info("CheckoutViewModel: Hydration complete")
            } catch {
                self.isBootstrappingCheckout = false
                self.isLoadingServices = false
                Logger.checkout.error("CheckoutViewModel: Load failed - \(error.localizedDescription)")
                self.appError = .database(
                    String(format: NSLocalizedString("checkout.load_services_failed_fmt", value: "Failed to load services: %@", comment: ""), error.localizedDescription)
                )
            }
        }
    }

    @MainActor
    private func hydrateStateFromVisit() {
        Logger.checkout.info("CheckoutViewModel: Hydrating from visit \(self.visit.uuid)")
        suppressDraftAutosave = true
        selectedLoyaltyReward = nil
        sessionNotes = TextInputLimits.limited(visit.note?.trimmed ?? "", to: TextInputLimits.notes)

        if visit.behaviorTags.isEmpty {
            // For a new visit session, we want to record this visit's observed behavior.
            // Preserve standing care tags like Special Needs, but do not pre-select
            // Aggressive or Calm/Cooperative so groomers can explicitly rate this session
            // without being trapped by old states.
            let standingTags = pet.behaviorTags.filter { tag in
                Pet.behaviorTagKind(for: tag) == .specialNeeds
            }
            tags = Set(standingTags)
        } else {
            tags = Set(BehaviorTagIcons.selectedTags(from: visit.behaviorTags))
        }

        beforePhotoData = visit.beforePhotoData
        afterPhotoData  = visit.afterPhotoData

        let allIDs = Set((visit.items ?? []).compactMap { $0.service?.persistentModelID })
        selectedServiceIDs = allIDs.filter { id in allServices.contains(where: { $0.persistentModelID == id }) }
        selectedAddOnIDs = allIDs.filter { id in addOnServices.contains(where: { $0.persistentModelID == id }) }

        if visit.isCompleted && visit.total > 0 {
            amountString = visit.total.moneyString
        } else {
            amountString = ""
        }

        recalculateCachedStrings()
        suppressDraftAutosave = false
        trace("hydrated_from_visit")
    }

    func setAmountDirectly(_ text: String) {
        amountString = text
        recalculateCachedStrings()
        scheduleDraftSave(reason: "amount_changed")
    }

    func setSessionNotes(_ text: String) {
        sessionNotes = TextInputLimits.limited(text, to: TextInputLimits.notes)
        scheduleDraftSave(reason: "session_notes_changed")
    }

    func setExternalReference(_ text: String) {
        let normalized = selectedPaymentMethod.normalizeReference(text)
        externalReference = TextInputLimits.limited(normalized, to: TextInputLimits.shortText)
        scheduleCriticalDraftSave(reason: "reference_changed")
    }

    func isServiceSelected(_ service: Service) -> Bool {
        selectedServiceIDs.contains(service.persistentModelID)
    }

    func isAddOnSelected(_ service: Service) -> Bool {
        selectedAddOnIDs.contains(service.persistentModelID)
    }

    func updateVisitItems() {
        recalculateCachedStrings()
    }

    func toggleService(_ service: Service) {
        let id = service.persistentModelID
        if selectedServiceIDs.contains(id) {
            selectedServiceIDs.remove(id)
        } else {
            selectedServiceIDs.insert(id)
        }
        recalculateCachedStrings()
        trace("service_toggled_\(service.name)")
    }

    func toggleAddOn(_ service: Service) {
        let id = service.persistentModelID
        if selectedAddOnIDs.contains(id) {
            selectedAddOnIDs.remove(id)
        } else {
            selectedAddOnIDs.insert(id)
        }
        recalculateCachedStrings()
        trace("addon_toggled_\(service.name)")
    }

    func removeVisitItem(_ item: VisitItem) {
        if let serviceID = item.service?.persistentModelID {
            selectedServiceIDs.remove(serviceID)
            selectedAddOnIDs.remove(serviceID)
        }
        recalculateCachedStrings()
    }

    /// The groomer chooses the visit amount. Service selection never assigns a price.
    var servicesTotalDecimal: Decimal {
        baseAmountDecimal.roundedMoney()
    }

    private var baseAmountDecimal: Decimal {
        if let manual = Formatters.parseCurrency(amountString) {
            return manual.roundedMoney()
        }
        return .zero
    }

    func toggleTag(_ raw: String) {
        if tags.contains(raw) {
            tags.remove(raw)
        } else {
            tags.insert(raw)
            // Care needs are independent; aggression and non-aggressive observations cannot coexist.
            if Pet.isAggressiveTag(raw) {
                tags.subtract(tags.filter { Pet.isNonAggressiveObservation($0) })
            } else if Pet.isNonAggressiveObservation(raw) {
                tags.subtract(tags.filter { Pet.isAggressiveTag($0) })
                tags.subtract(tags.filter {
                    $0 != raw && Pet.isNonAggressiveObservation($0)
                        && !(Pet.isCalmOrCooperativeTag(raw) && Pet.isCalmOrCooperativeTag($0))
                })
            }
        }
        recalculateCachedStrings()
        scheduleCriticalDraftSave(reason: "behavior_tags_changed")
    }

    func choosePayment(_ method: Payment.Method) {
        let previousMethod = selectedPaymentMethod
        let existingReference = externalReference
        selectedPaymentMethod = method

        if !method.requiresExternalReference {
            externalReference = ""
        } else if method.preservesReference(whenSwitchingFrom: previousMethod) {
            externalReference = TextInputLimits.limited(method.normalizeReference(existingReference), to: TextInputLimits.shortText)
        } else {
            externalReference = ""
        }

        trace("payment_method_selected_\(method.rawValue)")
        scheduleCriticalDraftSave(reason: "payment_method_finalized")
    }

    @MainActor
    func formatAmountInput() {
        let trimmed = amountString.trimmed
        if trimmed.isEmpty {
            amountString = ""
            return
        }
        if let dec = Formatters.parseCurrency(trimmed) {
            amountString = dec.moneyString
        } else {
            amountString = trimmed
        }
        recalculateCachedStrings()
        scheduleDraftSave(reason: "amount_formatted")
    }

    private func recalculateCachedStrings() {
        finalTotalString = paymentTotalDecimal.moneyString

        let allSelected = selectedServiceIDs.union(selectedAddOnIDs)
        let sortedNames = (allServices + addOnServices)
            .filter { allSelected.contains($0.persistentModelID) }
            .map(\.name)
            .sorted()

        selectedServicesSummary = sortedNames.isEmpty
            ? NSLocalizedString("common.none", value: "None", comment: "")
            : sortedNames.joined(separator: ", ")
    }

    var isAdvanceEnabled: Bool {
        switch currentStep {
        case .services:
            return hasSelectedServices
        case .details:
            return true
        case .payment:
            return isConfirmEnabled
        case .review:
            return isConfirmEnabled && !isSaving
        }
    }

    func goBack() {
        guard currentStep.rawValue > CheckoutFlowStep.services.rawValue else { return }
        currentStep = CheckoutFlowStep(rawValue: currentStep.rawValue - 1) ?? .services
        HapticManager.play(.step)
        trace("step_back_to_\(currentStep.rawValue)")
        scheduleCriticalDraftSave(reason: "step_back")
    }

    func advance() throws {
        try validate(step: currentStep)
        guard currentStep != .review else { return }
        currentStep = CheckoutFlowStep(rawValue: currentStep.rawValue + 1) ?? .review
        HapticManager.play(.step)
        trace("step_advanced_to_\(currentStep.rawValue)")
        scheduleCriticalDraftSave(reason: "step_advanced")
    }

    // MARK: - Guided tour preview

    /// Enters tour preview: from now on this checkout saves nothing. Any
    /// pending draft write is cancelled.
    func beginWalkthroughPreview() {
        guard !isWalkthroughPreview else { return }
        isWalkthroughPreview = true
        autosaveTask?.cancel()
        autosaveTask = nil
        trace("walkthrough_preview_started")
    }

    /// Shows a step for the tour without validating or saving it. Only works
    /// in tour preview, so real checkouts still go through `advance()`.
    func showStepForWalkthrough(_ step: CheckoutFlowStep) {
        guard isWalkthroughPreview, currentStep != step else { return }
        currentStep = step
    }

    /// Leaves tour preview if the checkout outlives the tour. The tour jumped
    /// steps without validation, so the checkout starts over at Services, and
    /// the fingerprint is re-based so the tour's state isn't saved as a draft.
    func endWalkthroughPreview() {
        guard isWalkthroughPreview else { return }
        currentStep = .services
        isWalkthroughPreview = false
        trace("walkthrough_preview_ended")
    }

    func dismissDraftRecoveryNotice() {
        guard draftRecoveryNotice != nil else { return }
        draftRecoveryNotice = nil
        trace("draft_notice_dismissed")
    }

    func discardRecoveredDraft() async {
        guard draftRecoveryNotice != nil else { return }

        autosaveTask?.cancel()
        draftRecoveryNotice = nil
        currentStep = .services
        hydrateStateFromVisit()

        do {
            try await draftStore.deleteDraft(for: visit.uuid)
        } catch {
            Logger.checkout.error("CheckoutViewModel: Draft discard cleanup failed - \(error.localizedDescription)")
        }

        trace("draft_discarded")
    }

    @MainActor
    func processPayment() async {
        guard !isSaving, state != .confirmed else { return }
        // The guided tour intercepts Confirm, but a keyboard shortcut or a
        // stray tap must still never save a checkout the tour opened.
        guard !isWalkthroughPreview else {
            trace("confirm_blocked_walkthrough_preview")
            return
        }
        guard currentStep == .review else {
            self.appError = .validation(.custom(message: AppLocalization.localized("checkout.error.review_first", value: "Review checkout before confirming payment.")))
            return
        }

        do {
            try validate(step: .review)
        } catch {
            self.appError = .validation(error as? ValidationError ?? .custom(message: error.localizedDescription))
            HapticManager.notify(.warning)
            return
        }

        guard let transactionActor else {
            // Checkout was attempted before `loadServices(modelContext:)` wired up the
            // real ModelContainer. Fail loudly instead of silently writing to a phantom store.
            Logger.checkout.error("CheckoutViewModel: processPayment invoked before transactionActor was initialized")
            let appErr = AppError.database(AppLocalization.localized("checkout.error.not_ready", value: "Checkout isn't ready yet. Please reopen the screen and try again."))
            state = .failed(appErr)
            appError = appErr
            return
        }

        guard acceptConfirmAttempt() else {
            trace("confirm_pay_debounced")
            return
        }

        isSaving = true
        state = .processing
        appError = nil
        Logger.checkout.info("CheckoutViewModel: Checkout started")
        trace("confirm_pay_tapped")
        HapticManager.play(.confirmation)
        HapticManager.prepare(.success)

        let request = CheckoutRequest(
            visitUUID: visit.uuid,
            petUUID: pet.uuid,
            clientUUID: pet.owner?.uuid,
            amount: servicesTotalDecimal,
            paymentMethod: selectedPaymentMethod,
            externalReference: externalReference.trimmed.isEmpty ? nil : externalReference.trimmed,
            sessionNotes: sessionNotes.trimmed.isEmpty ? nil : sessionNotes.trimmed,
            behaviorTags: Array(tags.sorted()),
            beforePhotoData: beforePhotoData,
            afterPhotoData: afterPhotoData,
            selectedServiceIDs: Array(selectedServiceIDs),
            selectedAddOnIDs: Array(selectedAddOnIDs),
            selectedLoyaltyReward: selectedLoyaltyReward,
            expectedPaymentAmount: paymentTotalDecimal
        )

        do {
            let result = try await transactionActor.process(request)
            completedLoyaltyPoints = result.earnedPoints
            if let balance = result.savedLoyaltyBalance { loyaltyPoints = balance }
            finalTotalString = result.total.moneyString

            autosaveTask?.cancel()
            do {
                try await draftStore.deleteDraft(for: visit.uuid)
            } catch {
                Logger.checkout.error("CheckoutViewModel: Draft cleanup failed after checkout - \(error.localizedDescription)")
            }

            // Refresh `self.visit` in the main context without writing stale UI state
            // over the transaction actor's committed checkout changes.
            let visitID = result.visitID
            let context = (pet.modelContext ?? visit.modelContext)

            if let mainContext = context {
                do {
                    let reader = ModelContext(mainContext.container)
                    let descriptor = FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.persistentModelID == visitID })
                    if let refreshed = try reader.fetch(descriptor).first {
                        completionContext = reader
                        self.visit = refreshed
                        if let freshPet = refreshed.pet { self.pet = freshPet }
                    } else {
                        Logger.checkout.error("CheckoutViewModel: Checkout saved but refreshed visit was not found in the main context")
                    }
                } catch {
                    Logger.checkout.error("CheckoutViewModel: Checkout saved but main-context refresh failed - \(error.localizedDescription)")
                }
            }

            state = .confirmed
            isSaving = false
            draftRecoveryNotice = nil

            // Clear photo data to free memory
            self.beforePhotoData = nil
            self.afterPhotoData = nil
            
            let completion = CheckoutCompletionContext(
                visitID: result.visitID,
                petID: result.petID,
                clientID: result.clientID,
                endedAt: result.endedAt,
                total: result.total
            )
            eventBus.publish(.checkoutCompleted(completion))

            var userInfo: [String: Any] = [
                VisitDidCompleteKey.visitID.rawValue: result.visitID,
                VisitDidCompleteKey.endedAt.rawValue: result.endedAt,
                VisitDidCompleteKey.total.rawValue: result.total
            ]
            if let petID = result.petID { userInfo[VisitDidCompleteKey.petID.rawValue] = petID }
            if let clientID = result.clientID { userInfo[VisitDidCompleteKey.clientID.rawValue] = clientID }
            
            NotificationCenter.default.post(name: .visitDidComplete, object: nil, userInfo: userInfo)
            
            Logger.checkout.info("CheckoutViewModel: Checkout saved successfully via Actor")
            trace("checkout_saved")
            HapticManager.notify(.success)
        } catch {
            Logger.checkout.error("CheckoutViewModel: Persistence failed - \(error.localizedDescription)")
            Logger.database.error("Local save failed: \(error.localizedDescription, privacy: .public)")
            let appErr = AppError.database(String(format: AppLocalization.localized("checkout.error.save_failed_fmt", value: "Persistence failed: %@"), error.localizedDescription))
            state = .failed(appErr)
            appError = appErr
            isSaving = false
            trace("checkout_save_failed")
            HapticManager.notify(.error)
        }
    }

    func flushDraft() {
        guard !isWalkthroughPreview else { return }
        if state == .confirmed {
            Task { [draftStore, visitID = visit.uuid] in
                do {
                    try await draftStore.deleteDraft(for: visitID)
                } catch {
                    Logger.checkout.error("CheckoutViewModel: Confirmed draft cleanup failed - \(error.localizedDescription)")
                }
            }
            return
        }
        scheduleDraftSave(reason: "view_disappeared", immediate: true)
    }

    private func validate(step: CheckoutFlowStep) throws {
        switch step {
        case .services:
            guard hasSelectedServices else {
                throw ValidationError.custom(message: AppLocalization.localized("checkout.error.no_services", value: "Select at least one service before continuing."))
            }
        case .details:
            break
        case .payment, .review:
            let total = servicesTotalDecimal
            guard total >= 0 && (total > 0 || isSpaRedeemed) else {
                throw ValidationError.custom(message: AppLocalization.localized("checkout.error.zero_total", value: "Cannot check out with a total amount of zero."))
            }
            guard isLoyaltySelectionValid else {
                throw ValidationError.custom(message: AppLocalization.localized("loyalty.error.reward_unavailable", value: "This reward is no longer available. Please reopen rewards."))
            }
            if requiresExternalReference, let message = selectedPaymentMethod.validationMessage(for: externalReference) {
                throw ValidationError.custom(message: message)
            }
        }
    }

    private func restoreDraftIfAvailable() async {
        guard !isWalkthroughPreview, !visit.isCompleted else { return }
        guard let draft = await draftStore.loadDraft(for: visit.uuid), draft.petID == pet.uuid else { return }
        guard !isWalkthroughPreview else { return }

        suppressDraftAutosave = true
        sessionNotes = TextInputLimits.limited(draft.sessionNotes, to: TextInputLimits.notes)
        amountString = draft.amountString
        // A tip saved by an earlier version is left out: checkout no longer
        // takes tips, and a hidden one would change the total.
        externalReference = TextInputLimits.limited(draft.externalReference, to: TextInputLimits.shortText)
        tags = Set(BehaviorTagIcons.selectedTags(from: draft.tags))
        selectedLoyaltyReward = draft.selectedLoyaltyReward
        
        if let method = Payment.Method(rawValue: draft.selectedPaymentMethodRawValue) {
            selectedPaymentMethod = method
        }

        let mainIDs = Set(allServices.filter { draft.selectedServiceUUIDs.contains($0.uuid) }.map(\.persistentModelID))
        let addOnIDs = Set(addOnServices.filter { draft.selectedAddOnUUIDs.contains($0.uuid) }.map(\.persistentModelID))
        selectedServiceIDs = mainIDs
        selectedAddOnIDs = addOnIDs
        if let restoredStep = CheckoutFlowStep(rawValue: draft.currentStepRawValue) {
            currentStep = restoredStep
        } else {
            // Don't silently regress to step 1 — that confuses the user when their
            // selections look filled in but the wizard rewinds. Log loudly, leave
            // the user where they were (default `currentStep` from init).
            Logger.checkout.error("Draft restore: unknown step rawValue=\(draft.currentStepRawValue, privacy: .public). Keeping current step.")
        }
        recalculateCachedStrings()
        draftRecoveryNotice = DraftRecoveryNotice(
            restoredAt: draft.updatedAt,
            missingBeforePhoto: draft.hadBeforePhoto && beforePhotoData == nil,
            missingAfterPhoto: draft.hadAfterPhoto && afterPhotoData == nil
        )
        suppressDraftAutosave = false
        trace("draft_restored")
    }

    // MARK: - Draft Persistence

    private func scheduleCriticalDraftSave(reason: String) {
        scheduleDraftSave(reason: reason, immediate: true)
    }

    private func scheduleDraftSave(reason: String, immediate: Bool = false) {
        guard !isWalkthroughPreview, !suppressDraftAutosave, !isBootstrappingCheckout, state != .confirmed, !visit.isCompleted else { return }

        autosaveTask?.cancel()

        let draft = makeDraft()
        let revision = CheckoutDraftStore.nextRevision()

        autosaveTask = Task { [draft, revision, draftStore, eventRecorder, visitID = visit.uuid, petName = pet.name] in
            if !immediate {
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch {
                    return
                }
            }
            if Task.isCancelled { return }
            do {
                try await draftStore.saveDraft(draft, revision: revision)
                await eventRecorder.record("draft_saved:\(reason)", visitID: visitID, petName: petName)
            } catch {
                Logger.checkout.error("Checkout draft save failed - \(error.localizedDescription)")
            }
        }
    }

    private func acceptConfirmAttempt(now: Date = .now) -> Bool {
        if let lastAcceptedConfirmAt,
           now.timeIntervalSince(lastAcceptedConfirmAt) < confirmDebounceWindow {
            return false
        }
        lastAcceptedConfirmAt = now
        return true
    }

    private func makeDraft() -> CheckoutDraft {
        // Keep the autosave payload small and atomic. We only persist whether
        // photos existed so restore can warn the groomer to re-pick them after
        // an interruption without inflating the draft file with image blobs.
        CheckoutDraft(
            visitID: visit.uuid,
            petID: pet.uuid,
            updatedAt: .now,
            currentStepRawValue: currentStep.rawValue,
            sessionNotes: sessionNotes,
            amountString: amountString,
            selectedServiceUUIDs: allServices.filter { selectedServiceIDs.contains($0.persistentModelID) }.map(\.uuid),
            selectedAddOnUUIDs: addOnServices.filter { selectedAddOnIDs.contains($0.persistentModelID) }.map(\.uuid),
            selectedPaymentMethodRawValue: selectedPaymentMethod.rawValue,
            beforePhotoData: nil,
            afterPhotoData: nil,
            hadBeforePhoto: beforePhotoData != nil,
            hadAfterPhoto: afterPhotoData != nil,
            externalReference: externalReference,
            tags: Array(tags.sorted()),
            selectedLoyaltyReward: selectedLoyaltyReward
        )
    }

    private func trace(_ event: String) {
        let visitID = visit.uuid
        let petName = pet.name
        Task { [eventRecorder] in
            await eventRecorder.record(event, visitID: visitID, petName: petName)
        }
    }

}

private extension Logger {
    static let checkout = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "Checkout")
}
