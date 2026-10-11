//
//  CheckoutView.swift
//  Pawtrackr
//

import SwiftUI
import SwiftData
import CoreTransferable

struct CheckoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(GlobalEventBus.self) private var eventBus
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    @State private var viewModel: CheckoutViewModel
    @State private var receiptPDFData: Data?
    @State private var receiptFailed = false
    @State private var isGoingBack = false
    @State private var notesEditorText: String = ""
    @State private var amountEditorText: String = ""
    @State private var referenceEditorText: String = ""
    @State private var notesSyncTask: Task<Void, Never>?
    @State private var amountSyncTask: Task<Void, Never>?
    @State private var confirmationBouncePhase: Bool = false
    @State private var didLoadViewModel = false
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case sessionNotes
        case amount
        case externalReference
    }

    private let paymentReferenceScrollTarget = "checkout.referenceField.anchor"

    init(pet: Pet, visit: Visit) {
        _viewModel = State(initialValue: CheckoutViewModel(pet: pet, visit: visit, eventBus: GlobalEventBus()))
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator

            if let notice = viewModel.draftRecoveryNotice {
                draftRecoveryBanner(notice)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            stepContent
                .frame(maxWidth: checkoutContentMaxWidth, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)

            bottomBar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkout.content")
        .sheet(isPresented: $viewModel.isChoosingLoyaltyReward) {
            CheckoutRewardSelectionView(points: viewModel.loyaltyPoints, rewards: viewModel.loyaltyRewards) { reward in
                viewModel.chooseLoyaltyReward(reward)
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .safeAreaPadding(.bottom)
        .background(DS.ColorToken.background.ignoresSafeArea())
        #if os(macOS)
        // Roomy on the Mac: the sheet opens at its ideal size, and pushed in
        // a window's detail column it fills the column.
        .frame(
            minWidth: 560, idealWidth: 960, maxWidth: .infinity,
            minHeight: 600, idealHeight: 780, maxHeight: .infinity
        )
        .presentationSizing(.fitted)
        #endif
        .navigationTitle(viewModel.currentStep.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                    .pressScaleStyle().disabled(viewModel.isSaving)
                    .accessibilityLabel(AppLocalization.localized("common.cancel", value: "Cancel"))
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(NSLocalizedString("common.done", comment: "")) {
                    if focusedField == .amount {
                        commitAmountInput()
                    }
                    focusedField = nil
                }
            }
        }
        #endif
        .alert(item: $viewModel.appError) { error in
            Alert(
                title: Text(NSLocalizedString("common.error", comment: "")),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "")))
            )
        }
        .onAppear {
            guard !didLoadViewModel else { return }
            didLoadViewModel = true
            viewModel = CheckoutViewModel(pet: viewModel.pet, visit: viewModel.visit, eventBus: eventBus)
            viewModel.loadServices(modelContext: modelContext)
            notesEditorText = viewModel.sessionNotes
            amountEditorText = viewModel.amountString
            referenceEditorText = viewModel.externalReference
            synchronizeWalkthroughCheckoutStep(walkthrough?.currentStep?.anchor)
        }
        .onDisappear {
            notesSyncTask?.cancel()
            amountSyncTask?.cancel()
            viewModel.flushDraft()
        }
        .onChange(of: viewModel.sessionNotes) { _, newValue in
            if focusedField != .sessionNotes && notesEditorText != newValue {
                notesEditorText = newValue
            }
        }
        .onChange(of: viewModel.amountString) { _, newValue in
            if focusedField != .amount && amountEditorText != newValue {
                amountEditorText = newValue
            }
        }
        .onChange(of: viewModel.externalReference) { _, newValue in
            if focusedField != .externalReference && referenceEditorText != newValue {
                referenceEditorText = newValue
            }
        }
        .onChange(of: walkthrough?.currentStep?.anchor) { _, anchor in
            synchronizeWalkthroughCheckoutStep(anchor)
        }
        .onChange(of: walkthrough?.isActive) { _, isActive in
            // A checkout the tour drove normally closes with the tour. If it
            // stays open, it becomes a normal checkout again, from Services.
            if isActive != true {
                viewModel.endWalkthroughPreview()
            }
        }
        .overlay {
            if shouldShowOverlay {
                overlayContent
                    .transition(.opacity)
            }
        }
        .modifier(CheckoutWalkthroughOverlayModifier(walkthrough: walkthrough))
        .animation(Animations.responsiveSpringSoft, value: shouldShowOverlay)
        #if os(macOS)
        .onChange(of: viewModel.currentStep) { _, newStep in
            guard !isGoingBack else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                switch newStep {
                case .payment: focusedField = .amount
                case .details: focusedField = .sessionNotes
                default: break
                }
            }
        }
        #endif
    }

    // MARK: - Overlay condition

    private var shouldShowOverlay: Bool {
        viewModel.isSaving || viewModel.state == .confirmed
    }

    // MARK: - Platform Adapters

    private var primaryButtonHeight: CGFloat {
        #if os(macOS)
        return 44
        #else
        return 50
        #endif
    }

    private let compactMaxWidth: CGFloat = 640
    private let macOSCheckoutMaxWidth: CGFloat = 940
    private let regularCheckoutMaxWidth: CGFloat = 860

    private var checkoutContentMaxWidth: CGFloat {
        #if os(macOS)
        return macOSCheckoutMaxWidth
        #else
        return horizontalSizeClass == .compact ? compactMaxWidth : regularCheckoutMaxWidth
        #endif
    }

    private var paymentGridColumns: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]
        #else
        if horizontalSizeClass == .compact {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)]
        #endif
    }

    // MARK: - Steps

    private var stepTransition: AnyTransition {
        .opacity
    }

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            switch viewModel.currentStep {
            case .services:
                servicesStep
                    .transition(Animations.slideIn)
            case .details:
                detailsStep
                    .transition(Animations.slideIn)
            case .payment:
                paymentStep
                    .transition(Animations.slideIn)
            case .review:
                reviewStep
                    .transition(Animations.slideIn)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Animations.interactiveSpring, value: viewModel.currentStep)
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(CheckoutViewModel.CheckoutFlowStep.allCases, id: \.self) { step in
                let isActive = viewModel.currentStep.rawValue >= step.rawValue
                VStack(spacing: 8) {
                    Circle()
                        .fill(isActive ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: isActive ? 12 : 10, height: isActive ? 12 : 10)
                    Text(step.title)
                        .font(stepTitleFont.weight(isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .animation(Animations.responsiveSpring, value: viewModel.currentStep)

                if step != .review {
                    Rectangle()
                        .fill(viewModel.currentStep.rawValue > step.rawValue ? Color.blue : Color.gray.opacity(0.2))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .offset(y: -12)
                        .animation(Animations.responsiveSpringSoft, value: viewModel.currentStep)
                }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 32)
        .frame(maxWidth: checkoutContentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var stepTitleFont: Font {
        #if os(macOS)
        return .subheadline
        #else
        return horizontalSizeClass == .compact ? .caption2 : .caption
        #endif
    }

    private var servicesStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                stepHero(
                    eyebrow: stepLabel(1),
                    title: localized("checkout.hero.services_title", value: "Pick the services"),
                    message: localized("checkout.hero.services_message", value: "Choose the main service and any add-ons before you move to notes and photos.")
                )
                .walkthroughTarget(.coServices)

                if viewModel.isLoadingServices {
                    servicesLoadingSkeleton
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("checkout.main_services", value: "Main Services")).font(.headline).padding(.horizontal)
                        Card {
                            if viewModel.allServices.isEmpty {
                                Text(NSLocalizedString("checkout.no_services_hint", comment: ""))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 8)
                            } else {
                                FlowLayout(spacing: 10, rowSpacing: 10) {
                                    ForEach(viewModel.allServices) { service in
                                        serviceTag(for: service)
                                    }
                                }
                            }
                        }
                    }

                    if !viewModel.addOnServices.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(NSLocalizedString("checkout.add_ons", comment: "")).font(.headline).padding(.horizontal)
                            VStack(spacing: 10) {
                                ForEach(viewModel.addOnServices) { service in
                                    addOnRow(service)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }

    private var detailsStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepHero(
                    eyebrow: stepLabel(2),
                    title: localized("checkout.hero.details_title", value: "Add notes and photos"),
                    message: localized("checkout.hero.details_message", value: "Capture behavior, grooming notes, and before/after photos without leaving checkout.")
                )
                .walkthroughTarget(.coDetails)

                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("checkout.notes_and_tags", comment: "")).font(.headline).padding(.horizontal)
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            FlowLayout(spacing: 10, rowSpacing: 10) {
                                ForEach(CheckoutViewModel.tagOptions, id: \.self) { tag in
                                    behaviorTag(for: tag)
                                }
                            }

                            if hasSafetyBehaviorWarning {
                                behaviorSafetyBanner
                            }
                            
                            TextEditor(text: $notesEditorText)
                                #if os(iOS)
                                .scrollContentBackground(.hidden)
                                #endif
                                .focused($focusedField, equals: .sessionNotes)
                                .accessibilityIdentifier("checkout.notesEditor")
                                .textLengthLimit($notesEditorText, to: TextInputLimits.notes)
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2)))
                                .onChange(of: notesEditorText) { _, newValue in
                                    notesSyncTask?.cancel()
                                    notesSyncTask = Task { @MainActor in
                                        do {
                                            try await Task.sleep(for: .milliseconds(400))
                                        } catch {
                                            return
                                        }
                                        viewModel.setSessionNotes(newValue)
                                    }
                                }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("checkout.before_after_photos", comment: "")).font(.headline).padding(.horizontal)
                    Card {
                        photoLayout
                    }
                }
            }
            .padding(.vertical)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    @ViewBuilder
    private var photoLayout: some View {
        #if os(iOS)
        VStack(spacing: 16) {
            PhotoWell(imageData: $viewModel.beforePhotoData, title: localized("checkout.photo.before", value: "Before"))
            PhotoWell(imageData: $viewModel.afterPhotoData, title: localized("checkout.photo.after", value: "After"))
        }
        #else
        HStack(spacing: 20) {
            PhotoWell(imageData: $viewModel.beforePhotoData, title: localized("checkout.photo.before", value: "Before"))
            PhotoWell(imageData: $viewModel.afterPhotoData, title: localized("checkout.photo.after", value: "After"))
        }
        #endif
    }

    private var paymentStep: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    stepHero(
                        eyebrow: stepLabel(3),
                        title: localized("checkout.hero.payment_title", value: "Confirm payment"),
                        message: localized("checkout.hero.payment_message", value: "Set the total and payment method before the final review.")
                    )
                    .walkthroughTarget(.coPayment)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("checkout.payment_method", comment: "")).font(.headline).padding(.horizontal)
                        LazyVGrid(columns: paymentGridColumns, spacing: 12) {
                            ForEach(Self.paymentOptions) { option in
                                paymentCard(for: option)
                            }
                        }
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("checkout.total_amount", comment: "")).font(.headline).padding(.horizontal)
                        Card {
                            TextField("$0.00", text: amountBinding)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .focused($focusedField, equals: .amount)
                                .accessibilityIdentifier("checkout.amountField")
                                .font(Font.system(size: 40, weight: .bold, design: .rounded))
                                .multilineTextAlignment(TextAlignment.center)
                                .foregroundStyle(Color.blue)
                                .onSubmit {
                                    commitAmountInput()
                                    #if os(macOS)
                                    focusedField = nil
                                    if viewModel.isAdvanceEnabled { advance() }
                                    #endif
                                }

                            Text(localized("checkout.auto_filled_from_services", value: "Auto-filled from selected services."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }

                    if viewModel.requiresExternalReference {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(viewModel.referenceFieldTitle).font(Font.subheadline.weight(.medium)).padding(.horizontal)
                            TextField(viewModel.referencePlaceholder, text: referenceBinding)
                                .focused($focusedField, equals: .externalReference)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)
                                .accessibilityIdentifier("checkout.referenceField")
                                .textLengthLimit($referenceEditorText, to: TextInputLimits.shortText)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .keyboardType(viewModel.selectedPaymentMethod.referenceFormat == .cardLast4 ? .numberPad : .asciiCapable)
                                #endif
                                #if os(macOS)
                                .onSubmit {
                                    viewModel.setExternalReference(referenceEditorText)
                                    if viewModel.isAdvanceEnabled { advance() }
                                }
                                #endif

                            Text(viewModel.referenceHelperText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            if let message = viewModel.referenceValidationMessage {
                                Text(message)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal)
                                    .accessibilityIdentifier("checkout.referenceValidation")
                            }
                        }
                        .id(paymentReferenceScrollTarget)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("checkout.summary", value: "Summary")).font(.headline).padding(.horizontal)
                        Card {
                            VStack(spacing: 10) {
                                summaryRow(title: localized("checkout.pet", value: "Pet"), value: viewModel.pet.name)
                                summaryRow(title: localized("checkout.duration", value: "Duration"), value: viewModel.sessionDurationString)
                                summaryRow(title: localized("checkout.services", value: "Services"), value: selectedServicesSummary)
                                Divider()
                                if viewModel.loyaltyCredit > .zero {
                                summaryRow(title: localized("checkout.loyalty.credit", value: "Reward credit"), value: "−" + viewModel.loyaltyCredit.moneyString)
                            }
                            summaryRow(title: NSLocalizedString("checkout.total", comment: ""), value: viewModel.finalTotalString, isTotal: true)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .onChange(of: viewModel.selectedPaymentMethod) { _, method in
                guard method.requiresExternalReference else { return }

                withAnimation(.easeInOut(duration: 0.24)) {
                    proxy.scrollTo(paymentReferenceScrollTarget, anchor: .center)
                }

                Task { @MainActor in
                    #if os(iOS)
                    try? await Task.sleep(for: .milliseconds(180))
                    #endif
                    focusedField = .externalReference
                }
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepHero(
                    eyebrow: stepLabel(4),
                    title: localized("checkout.hero.review_title", value: "Review everything"),
                    message: localized("checkout.hero.review_message", value: "Confirm exactly what will be saved to history and insights.")
                )
                .walkthroughTarget(.coReview)

                if entitlements.isPremium, viewModel.pet.owner != nil {
                    CheckoutLoyaltyReviewCard(viewModel: viewModel)
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(localized("checkout.visit_summary", value: "Visit Summary")).font(.headline).padding(.horizontal)
                    Card {
                        VStack(spacing: 10) {
                            summaryRow(title: localized("checkout.pet", value: "Pet"), value: viewModel.pet.name)
                            summaryRow(title: localized("checkout.duration", value: "Duration"), value: viewModel.sessionDurationString)
                            summaryRow(title: localized("checkout.services", value: "Services"), value: selectedServicesSummary)
                            summaryRow(title: NSLocalizedString("checkout.behavior_tags", comment: ""), value: viewModel.behaviorTagsSummary)
                            summaryRow(title: localized("checkout.notes", value: "Notes"), value: viewModel.notesPreview)
                            summaryRow(title: localized("checkout.photos", value: "Photos"), value: "\(viewModel.totalPhotoCount)")
                            Divider()
                            if viewModel.loyaltyCredit > .zero {
                                summaryRow(title: localized("checkout.loyalty.credit", value: "Reward credit"), value: "−" + viewModel.loyaltyCredit.moneyString)
                            }
                            summaryRow(title: NSLocalizedString("checkout.total", comment: ""), value: viewModel.finalTotalString, isTotal: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(localized("checkout.payment_review", value: "Payment Review")).font(.headline).padding(.horizontal)
                    Card {
                        VStack(spacing: 10) {
                            summaryRow(title: localized("checkout.method", value: "Method"), value: viewModel.paymentMethodLabel)
                            summaryRow(title: localized("checkout.reference_label", value: "Reference"), value: viewModel.paymentReferenceSummary)
                            summaryRow(
                                title: localized("checkout.history_save", value: "History Save"),
                                value: historySaveSummary
                            )
                            summaryRow(title: localized("checkout.insights_save", value: "Insights Save"), value: insightsSaveSummary)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Components

    private var headerCard: some View {
        Card {
            HStack(spacing: 16) {
                AvatarView(.pet(species: viewModel.pet.species, gender: viewModel.pet.gender, name: viewModel.pet.name, imageData: viewModel.pet.photoData), size: .md)
                VStack(alignment: .leading) {
                    Text(viewModel.pet.name).font(.headline)
                    Text(viewModel.pet.owner?.fullName ?? NSLocalizedString("common.unknown_owner", value: "Unknown Owner", comment: "")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(localized("checkout.started", value: "Started")).font(.caption).foregroundStyle(.secondary)
                    Text(viewModel.visit.startedAt, style: .time).font(Font.subheadline.weight(.medium))
                }
            }
        }
        .padding(.horizontal)
    }

    private func draftRecoveryBanner(_ notice: CheckoutViewModel.DraftRecoveryNotice) -> some View {
        Card(
            cornerRadius: 18,
            accent: .top(.color(notice.hasMissingPhotos ? .orange : .blue), thickness: 4)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: notice.hasMissingPhotos ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(notice.hasMissingPhotos ? .orange : .blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(localized("checkout.recovery.title", value: "Recovered Saved Checkout"))
                            .font(.headline)
                        Text(notice.detailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Button(NSLocalizedString("common.continue", comment: "")) {
                        viewModel.dismissDraftRecoveryNotice()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("checkout.recovery.continue")

                    Button(localized("checkout.recovery.discard", value: "Discard Draft"), role: .destructive) {
                        focusedField = nil
                        Task {
                            await viewModel.discardRecoveredDraft()
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("checkout.recovery.discard")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .accessibilityIdentifier("checkout.draftRecoveryBanner")
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                if viewModel.currentStep != .services {
                    Button {
                        isGoingBack = true
                        viewModel.goBack()
                    } label: {
                            Image(systemName: "chevron.left")
                                .font(.headline)
                                .frame(width: primaryButtonHeight, height: primaryButtonHeight)
                                .background(Circle().fill(Color.gray.opacity(0.1)))
                        }
                        .accessibilityIdentifier("checkout.backButton")
                    }
                
                Button {
                    advance()
                } label: {
                    Text(viewModel.currentStep.primaryButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: primaryButtonHeight)
                        .background(RoundedRectangle(cornerRadius: 15).fill(viewModel.isAdvanceEnabled ? Color.blue : Color.gray.opacity(0.3)))
                        .foregroundStyle(.white)
                        .scaleEffect(viewModel.isAdvanceEnabled ? 1.0 : 0.97)
                }
                .disabled(!viewModel.isAdvanceEnabled)
                .accessibilityIdentifier("checkout.primaryButton")
                .walkthroughTarget(.coConfirm)
                .animation(Animations.responsiveSpring, value: viewModel.isAdvanceEnabled)
                #if os(macOS)
                // Off during the guided tour: the overlay intercepts clicks on
                // this button, but not keyboard shortcuts, and ⌘Return on the
                // Review step would confirm a real payment.
                .keyboardShortcut(walkthrough?.isActive == true ? nil : KeyboardShortcut(.return))
                #endif
            }
            .frame(maxWidth: checkoutContentMaxWidth)
            .padding()
            .frame(maxWidth: .infinity)
            .background(DS.ColorToken.background)
        }
    }

    private func advance() {
        isGoingBack = false
        if viewModel.currentStep == .review {
            confirmCheckout()
            return
        }

        flushPendingEditors()
        focusedField = nil

        Task { @MainActor in
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif

            #if os(iOS)
            try? await Task.sleep(for: .milliseconds(120))
            #endif
            do {
                try viewModel.advance()
            } catch {
                viewModel.appError = .validation(error as? ValidationError ?? .custom(message: error.localizedDescription))
            }
        }
    }

    private func confirmCheckout() {
        flushPendingEditors()
        focusedField = nil
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        Task {
            await viewModel.processPayment()
        }
    }

    private func flushPendingEditors() {
        notesSyncTask?.cancel()
        amountSyncTask?.cancel()

        switch viewModel.currentStep {
        case .details:
            viewModel.setSessionNotes(notesEditorText)
        case .payment, .review:
            viewModel.setSessionNotes(notesEditorText)
            viewModel.setAmountDirectly(amountEditorText)
            viewModel.setExternalReference(referenceEditorText)
        case .services:
            break
        }
    }

    private func commitAmountInput() {
        amountSyncTask?.cancel()
        viewModel.setAmountDirectly(amountEditorText)
        viewModel.formatAmountInput()
        amountEditorText = viewModel.amountString
    }

    private func synchronizeWalkthroughCheckoutStep(_ anchor: WalkthroughAnchorID?) {
        guard walkthrough?.isActive == true,
              walkthrough?.currentStep?.presents == .checkout,
              let anchor
        else { return }

        let targetStep = CheckoutViewModel.CheckoutFlowStep.walkthroughStep(for: anchor)

        // The tour only shows these steps. Preview mode stops the checkout
        // from saving a draft or a payment for the visit it opened.
        viewModel.beginWalkthroughPreview()
        guard let targetStep, viewModel.currentStep != targetStep else { return }
        focusedField = nil
        isGoingBack = false
        viewModel.showStepForWalkthrough(targetStep)
    }

    private func stepHero(eyebrow: String, title: String, message: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.blue)
                Text(title)
                    .font(.title3.weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }

    private var overlayContent: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                if viewModel.state == .confirmed {
                    confirmedContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity
                        ))
                } else {
                    processingContent
                        .transition(.opacity)
                }
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 25).fill(DS.ColorToken.surface))
            .shadow(radius: 20)
            .animation(Animations.responsiveSpring, value: viewModel.state == .confirmed)
        }
        .onChange(of: viewModel.state) { _, newValue in
            if newValue == .confirmed {
                #if os(iOS)
                HapticManager.notify(.success)
                #endif
                let receiptSnapshot = PDFReceiptService.shared.makeSnapshot(for: viewModel.visit)
                Task {
                    let data: Data? = await withTaskGroup(of: Data?.self) { group in
                        group.addTask {
                            await Task.detached(priority: .userInitiated) {
                                PDFReceiptService.render(snapshot: receiptSnapshot)
                            }.value
                        }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(10))
                            return nil
                        }
                        let result = await group.next() ?? nil
                        group.cancelAll()
                        return result
                    }
                    if let data {
                        receiptPDFData = data
                    } else {
                        receiptFailed = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var confirmedContent: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: viewModel.state == .confirmed)
            }
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: confirmationBouncePhase
            ) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.35, duration: 0.0)
                    SpringKeyframe(1.18, duration: 0.34, spring: .bouncy(duration: 0.42, extraBounce: 0.28))
                    SpringKeyframe(1.0, duration: 0.20, spring: .smooth)
                }
            }
            .onAppear { confirmationBouncePhase.toggle() }
            
            VStack(spacing: 8) {
                Text(NSLocalizedString("checkout.complete_title", comment: ""))
                    .font(Font.title3.weight(.bold))
                Text(viewModel.finalTotalString)
                    .font(Font.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(.blue)
            }

            if viewModel.completedLoyaltyPoints > 0 {
                Label(String(format: AppLocalization.localized("checkout.loyalty.earned_fmt", value: "+%@ saved to the client’s account"), LoyaltyCopy.points(viewModel.completedLoyaltyPoints)), systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(DS.ColorToken.primary)
                    .accessibilityIdentifier("checkout.loyalty.saved")
            }

            if let pdfData = receiptPDFData {
                ShareLink(
                    item: ReceiptDocument(
                        pdfData: pdfData,
                        filename: "Receipt_\(viewModel.pet.name).pdf"
                    ),
                    preview: SharePreview(localized("receipt.title", value: "Receipt"))
                ) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(NSLocalizedString("receipt.share", comment: ""))
                    }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                }
                .transition(.scale.combined(with: .opacity))
            } else if receiptFailed {
                Label(localized("checkout.receipt_unavailable", value: "Receipt unavailable"), systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(NSLocalizedString("receipt.preparing", comment: "Preparing receipt…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                dismiss()
            } label: {
                Text(NSLocalizedString("common.done", comment: ""))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("checkout.doneButton")
        }
    }

    @ViewBuilder
    private var processingContent: some View {
        ProgressView()
            .scaleEffect(1.5)
        Text(NSLocalizedString("checkout.processing", value: "Processing Payment", comment: ""))
            .font(.headline)
        Text(NSLocalizedString("checkout.processing_desc", value: "Please wait while we complete your transaction...", comment: ""))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    func serviceTag(for service: Service) -> some View {
        let isSelected = viewModel.isServiceSelected(service)
        return Button {
            HapticManager.impact(.light)
            withAnimation(Animations.responsiveSpring) {
                viewModel.toggleService(service)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: service.systemIcon ?? "pawprint.fill")
                Text(service.name)
            }
            .font(Font.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(isSelected ? Color.blue.opacity(0.15) : Color.gray.opacity(0.05)))
            .overlay(Capsule().stroke(isSelected ? Color.blue : Color.gray.opacity(0.2), lineWidth: 1))
            .foregroundStyle(isSelected ? Color.blue : Color.primary)
            .scaleEffect(isSelected ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("checkout.service.\(service.name)")
        .animation(Animations.responsiveSpring, value: isSelected)
    }

    func addOnRow(_ service: Service) -> some View {
        let isSelected = viewModel.isAddOnSelected(service)
        return Button {
            HapticManager.impact(.light)
            withAnimation(Animations.responsiveSpring) {
                viewModel.toggleAddOn(service)
            }
        } label: {
            HStack {
                Image(systemName: service.systemIcon ?? "sparkles")
                    .foregroundStyle(Color.blue)
                    .frame(width: 30)
                Text(service.name).font(.subheadline)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.green : Color.gray)
                    .scaleEffect(isSelected ? 1.15 : 1.0)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 15).fill(DS.ColorToken.surface))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(isSelected ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("checkout.addOn.\(service.name)")
        .animation(Animations.responsiveSpring, value: isSelected)
    }

    private var servicesLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("checkout.main_services", value: "Main Services"))
                    .font(.headline)
                    .padding(.horizontal)
                Card {
                    FlowLayout(spacing: 10, rowSpacing: 10) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 110, height: 36)
                        }
                    }
                    .redacted(reason: .placeholder)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("checkout.add_ons", comment: ""))
                    .font(.headline)
                    .padding(.horizontal)
                VStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in
                        Card {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(width: 28, height: 28)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(width: 150, height: 12)
                                Spacer()
                                Circle()
                                    .fill(Color.secondary.opacity(0.10))
                                    .frame(width: 24, height: 24)
                            }
                            .redacted(reason: .placeholder)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 16)
    }

    func behaviorTag(for raw: String) -> some View {
        let isSelected = viewModel.tags.contains(raw)
        let display = BehaviorTagIcons.display(for: raw)
        let tint = behaviorTagTint(for: raw)
        return Button {
            HapticManager.impact(.light)
            viewModel.toggleTag(raw)
        } label: {
            HStack(spacing: 4) {
                if let emoji = display.emoji { Text(emoji) }
                Text(display.label)
            }
            .font(Font.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? tint.opacity(0.15) : Color.clear))
            .overlay(Capsule().stroke(isSelected ? tint : Color.gray.opacity(0.3), lineWidth: 1))
            .foregroundStyle(isSelected ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var safetyBehaviorTags: [Pet.BehaviorTag] {
        Pet.BehaviorTag.allCases.filter { tag in
            switch tag {
            case .aggressive, .specialNeeds:
                return viewModel.tags.contains { Pet.behaviorTagKind(for: $0) == tag }
            default:
                return false
            }
        }
    }

    private var hasSafetyBehaviorWarning: Bool {
        !safetyBehaviorTags.isEmpty
    }

    private var behaviorSafetyBanner: some View {
        let tags = safetyBehaviorTags
        let message: String
        if tags.contains(.aggressive), tags.contains(.specialNeeds) {
            message = localized(
                "checkout.safety_alert.aggressive_special_needs",
                value: "Aggressive and special-needs handling selected. Assign an experienced worker, use a calm approach, and review notes before continuing."
            )
        } else if tags.contains(.aggressive) {
            message = localized(
                "checkout.safety_alert.aggressive",
                value: "Aggressive behavior selected. Warn the team before handling, use a second worker if needed, and avoid rushed movements."
            )
        } else {
            message = localized(
                "checkout.safety_alert.special_needs",
                value: "Special needs selected. Review handling notes, medical or comfort needs, and assign extra time."
            )
        }

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.ColorToken.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("checkout.safety_alert.title", value: "Safety alert"))
                    .font(.subheadline.weight(.bold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.ColorToken.danger.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("checkout.behavior.safetyAlert")
    }

    private func behaviorTagTint(for raw: String) -> Color {
        switch Pet.behaviorTagKind(for: raw) {
        case .calm, .cooperative:
            return DS.ColorToken.success
        case .anxious:
            return DS.ColorToken.warning
        case .nervous:
            return DS.ColorToken.info
        case .aggressive:
            return DS.ColorToken.danger
        case .specialNeeds:
            return DS.ColorToken.primary
        case nil:
            return DS.ColorToken.warning
        }
    }

    func paymentCard(for option: PaymentOption) -> some View {
        let isSelected = viewModel.selectedPaymentMethod == option.method
        return Button {
            HapticManager.impact(.medium)
            withAnimation(Animations.responsiveSpring) {
                viewModel.choosePayment(option.method)
            }
        } label: {
            VStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.title2)
                Text(option.label).font(Font.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 15).fill(isSelected ? option.tint.opacity(0.1) : Color.gray.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(isSelected ? option.tint : Color.clear, lineWidth: 2))
            .foregroundStyle(isSelected ? option.tint : Color.secondary)
            .scaleEffect(isSelected ? 1.03 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.label)
        .accessibilityIdentifier("checkout.payment.\(option.method.rawValue)")
        .accessibilityValue(isSelected
            ? NSLocalizedString("common.selected", value: "Selected", comment: "")
            : NSLocalizedString("common.not_selected", value: "Not selected", comment: "")
        )
        .accessibilityAddTraits(.isButton)
        .animation(Animations.responsiveSpring, value: isSelected)
    }

    private func localized(_ key: String, value: String) -> String {
        AppLocalization.localized(key, value: value)
    }

    private func stepLabel(_ number: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("checkout.step_number_fmt", value: "Step %d", comment: ""),
            number
        )
    }

    private var historySaveSummary: String {
        switch viewModel.totalPhotoCount {
        case 0:
            return localized("checkout.history_save_without_photos", value: "Visit, services, notes, payment")
        case 1:
            return localized("checkout.history_save_with_one_photo", value: "Visit, 1 photo, services, notes, payment")
        default:
            return String.localizedStringWithFormat(
                NSLocalizedString("checkout.history_save_with_photos_fmt", value: "Visit, %d photos, services, notes, payment", comment: ""),
                viewModel.totalPhotoCount
            )
        }
    }

    private var insightsSaveSummary: String {
        String.localizedStringWithFormat(
            NSLocalizedString("checkout.insights_save_fmt", value: "%@ tracked as revenue", comment: ""),
            viewModel.finalTotalString
        )
    }

    func summaryRow(title: String, value: String, isTotal: Bool = false) -> some View {
        HStack {
            Text(title).font(isTotal ? Font.headline : Font.subheadline).foregroundStyle(Color.secondary)
            Spacer()
            Text(value).font(isTotal ? Font.headline.bold() : Font.subheadline).foregroundStyle(isTotal ? Color.blue : Color.primary)
        }
    }

    var amountBinding: Binding<String> {
        Binding(
            get: { amountEditorText },
            set: { newValue in
                let allowed = "0123456789" + (Locale.current.decimalSeparator ?? ".")
                let filtered = newValue.filter { allowed.contains($0) }
                amountEditorText = filtered
                amountSyncTask?.cancel()
                amountSyncTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    viewModel.setAmountDirectly(filtered)
                }
            }
        )
    }

    var referenceBinding: Binding<String> {
        Binding(
            get: { referenceEditorText },
            set: { newValue in
                let normalized = viewModel.selectedPaymentMethod.normalizeReference(newValue)
                let limited = TextInputLimits.limited(normalized, to: TextInputLimits.shortText)
                referenceEditorText = limited
                viewModel.setExternalReference(limited)
            }
        )
    }

    // Delegates to ViewModel so this is not recomputed on every render.
    var selectedServicesSummary: String { viewModel.selectedServicesSummary }

    struct PaymentOption: Identifiable {
        let id = UUID()
        let method: Payment.Method
        let icon: String
        let tint: Color
        var label: String { method.displayName }
    }

    static let paymentOptions: [PaymentOption] = [
        PaymentOption(method: .cash,       icon: "banknote",          tint: .green),
        PaymentOption(method: .creditCard, icon: "creditcard",         tint: .blue),
        PaymentOption(method: .debitCard,  icon: "creditcard.fill",    tint: .purple),
        PaymentOption(method: .zelle,      icon: "dollarsign.circle",  tint: .yellow),
        PaymentOption(method: .other,      icon: "ellipsis.circle",    tint: .gray),
    ]
}

extension CheckoutViewModel.CheckoutFlowStep {
    /// The checkout step each guided-tour stop shows, or nil for stops that
    /// aren't inside checkout.
    static func walkthroughStep(for anchor: WalkthroughAnchorID) -> Self? {
        switch anchor {
        case .coServices: return .services
        case .coDetails: return .details
        case .coPayment: return .payment
        case .coReview, .coConfirm: return .review
        default: return nil
        }
    }
}

private struct CheckoutWalkthroughOverlayModifier: ViewModifier {
    let walkthrough: WalkthroughController?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let walkthrough {
            content.walkthroughOverlay(walkthrough, presenting: .checkout)
        } else {
            content
        }
    }
}
