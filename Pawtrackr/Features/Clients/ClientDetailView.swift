//
//  ClientDetailView.swift
//  Pawtrackr
//
//  Created by mac on 8/15/25.
//  Updated by Assistant on 2025-09-03.
//

import SwiftUI
import SwiftData
import OSLog

private struct ClientCheckoutRoute: Identifiable {
    let pet: Pet
    let visit: Visit

    var id: String {
        "checkout_\(pet.uuid.uuidString)_\(visit.uuid.uuidString)"
    }
}

@MainActor
struct ClientDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Practice clients are never offered to Handoff or Siri.
    @Environment(\.isPracticeSalon) private var isPracticeSalon
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(GlobalEventBus.self) private var eventBus
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    @Environment(EntitlementStore.self) private var entitlements

    // Lazy-initialized ViewModel to avoid context crashes
    @State private var viewModel: ClientDetailViewModel? = nil

    // Local sheet routing (do not depend on VM for UI routing)
    @State private var sheetDestination: SheetDestination?
    @State private var checkoutRoute: ClientCheckoutRoute? = nil
    @State private var isWalkthroughDrivingCheckout = false
    /// The emergency contact form was opened on the tour's "+" stop, so
    /// closing it moves the tour on.
    @State private var walkthroughOpenedContactEditor = false

    enum SheetDestination: Identifiable {
        case addPet
        case editPet(Pet)
        case editClient
        case history(Pet)
        case communication(Pet)
        case subscriptionPaywall

        var id: String {
            switch self {
            case .addPet:
                return "addPet"
            case .editPet(let pet):
                return "editPet-\(pet.uuid)"
            case .editClient:
                return "editClient"
            case .history(let pet):
                return "history_\(String(describing: pet.persistentModelID))"
            case .communication(let pet):
                return "communication_\(String(describing: pet.persistentModelID))"
            case .subscriptionPaywall:
                return "subscriptionPaywall"
            }
        }
    }
    
    enum AlertDestination: Identifiable {
        case checkIn(Pet)
        case deleteClient
        case deleteError(String)
        case deleteContact(EmergencyContact)
        case inlineEditConflict(name: String)
        case inlineEditFailed(String)

        var id: String {
            switch self {
            case .checkIn(let pet):
                return "checkIn_\(pet.uuid.uuidString)"
            case .deleteClient:
                return "deleteClient"
            case .deleteError:
                return "deleteError"
            case .deleteContact:
                // Singleton id — only one contact-delete alert can be in
                // flight at a time. Folding contact deletion into this enum
                // lets a single `.alert(item:)` host every confirmation,
                // which avoids SwiftUI's stacked-deprecated-Alert
                // presentation bug where the second `.alert(item:)`
                // silently never fires (the original cause of the trash
                // button looking broken).
                return "deleteContact"
            case .inlineEditConflict:
                return "inlineEditConflict"
            case .inlineEditFailed:
                return "inlineEditFailed"
            }
        }
    }

    @State private var alertDestination: AlertDestination?
    @State private var showContactEditor = false
    @State private var editingContact: EmergencyContact? = nil
    @State private var newContactName: String = ""
    @State private var newContactRelation: String = ""
    @State private var newContactPhone: String = ""
    @State private var validationError: String? = nil
    @State private var contactNameError: String? = nil
    @State private var contactPhoneError: String? = nil
    @FocusState private var contactNameFocused: Bool

    // Inline client edit state
    @State private var isEditingClientInline = false
    @State private var editFirst: String = ""
    @State private var editLast: String = ""
    @State private var editPhone: String = ""
    @State private var editEmail: String = ""
    /// What the inline edit opened with, for the changed-on-another-device check.
    @State private var inlineEditBaseline: ClientEditBaseline? = nil

    @Environment(NavigationRouter.self) private var router
    @State private var profileRewards: [LoyaltyReward] = []
    @State private var loyaltyBalance: LoyaltyBalanceState
    private var namespace: Namespace.ID
    /// Every tour stop on this screen, so each one is scrolled into view.
    static let walkthroughAnchors: Set<WalkthroughAnchorID> = [
        .cdOwner,
        .cdEmergency,
        .emergencyContactBadges,
        .cdLoyalty,
        .cdPets,
        .petGenderDots,
        .cdAddPet,
        .cdCheckIn,
        .cdCheckOut,
        .cdPetHistory,
        .cdHistory,
        .cdVisitRow
    ]

    // MARK: - Init
    private let client: Client
    init(client: Client, namespace: Namespace.ID) {
        self.client = client
        self.namespace = namespace
        _loyaltyBalance = State(initialValue: LoyaltyBalanceState(points: client.loyaltyPoints))
    }

    // MARK: - Body
    var body: some View {
        Group {
            if let vm = viewModel {
                navigationContent(vm: vm)
            } else {
                ProgressView()
                    .padding()
            }
        }
        .loyaltyBalanceTracking(loyaltyBalance, clientUUID: client.uuid)
        .onAppear {
            if viewModel == nil {
                let ctx = client.modelContext ?? modelContext
                viewModel = ClientDetailViewModel(client: client, modelContext: ctx, eventBus: eventBus)
            } else {
                viewModel?.refreshPets()
                viewModel?.refreshRecentVisits()
            }
        }
    }

    private func navigationContent(vm: ClientDetailViewModel) -> some View {
        content(vm: vm)
            .environment(\.modelContext, vm.client.modelContext ?? modelContext)
            .navigationTitle("client_details.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .userActivity("com.pawtrackr.viewClient", isActive: !isPracticeSalon) { activity in
                activity.title = String(
                    format: AppLocalization.localized("handoff.viewing_fmt", value: "Viewing %@"),
                    client.fullName
                )
                activity.userInfo = ["clientID": client.uuid.uuidString]
                activity.isEligibleForHandoff = true
            }
            .toolbar {
                toolbarContent(vm)
                macAddPetToolbarItem
            }
            #if os(iOS)
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                if usesFloatingAddPetAction {
                    addPetFab
                        .padding(.trailing, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                }
            }
            #endif
            .sheet(item: $sheetDestination) { destination in
                destinationSheet(destination, vm: vm)
            }
            .sheet(isPresented: $showContactEditor) {
                contactEditorSheet
            }
            .modifier(CheckoutPresentationModifier(checkoutRoute: $checkoutRoute, vm: vm, walkthrough: walkthrough))
            .onAppear {
                synchronizeWalkthroughCheckoutPresentation(walkthrough?.currentStep?.presents, vm: vm)
                releaseWalkthroughCheckInIfAlreadyInSession(vm: vm)
                releaseWalkthroughCheckOutIfNothingIsCheckedIn(vm: vm)
            }
            .onChange(of: walkthrough?.currentStep?.presents) { _, presentation in
                synchronizeWalkthroughCheckoutPresentation(presentation, vm: vm)
            }
            .onChange(of: walkthrough?.currentStep?.anchor) { _, _ in
                releaseWalkthroughCheckInIfAlreadyInSession(vm: vm)
                releaseWalkthroughCheckOutIfNothingIsCheckedIn(vm: vm)
            }
            .onChange(of: showContactEditor) { _, isShowing in
                continueWalkthroughAfterContactEditor(isShowing: isShowing)
            }
            // The Academy's Add Pet mission ends when the form closes, whether
            // a pet was saved or not.
            .onChange(of: sheetDestination?.id) { oldID, newID in
                if oldID == SheetDestination.addPet.id, newID == nil {
                    walkthrough?.observe(.addPetClosed)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clientDidUpdate)) { _ in
                vm.refreshPets()
            }
            .onReceive(NotificationCenter.default.publisher(for: .visitDidStart)) { notification in
                continueWalkthroughAfterVisitStart(notification, vm: vm)
            }
            // The deprecated `.alert(item:)` + `Alert(…)` API silently fails to
            // present when stacked under multiple `.sheet(item:)` modifiers
            // — that's why the Check In button looked broken to the user
            // (the alert never appeared, so vm.checkIn was never called).
            // Use the modern actions/message API instead.
            .alert(
                alertTitleText(for: alertDestination, vm: vm),
                isPresented: Binding(
                    get: { alertDestination != nil },
                    set: { if !$0 { alertDestination = nil } }
                ),
                presenting: alertDestination,
                actions: { destination in
                    alertActions(for: destination, vm: vm)
                },
                message: { destination in
                    alertMessage(for: destination)
                }
            )
            .onChange(of: (vm.client.pets ?? []).count) { oldCount, newCount in
                vm.refreshPets()
                // The tour's Add a New Pet stop moves on once a pet is saved.
                if newCount > oldCount {
                    walkthrough?.observe(.petAdded)
                }
            }
            .onChange(of: (vm.client.emergencyContacts ?? []).count) { _, _ in
                vm.refreshEmergencyContacts()
            }
            .task {
                vm.refreshEmergencyContacts()
                vm.refreshRecentVisits()
            }
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var macAddPetToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { sheetDestination = .addPet } label: {
                Label(NSLocalizedString("a11y.add_new_pet", comment: ""), systemImage: "pawprint.fill")
            }
        }
    }
    #else
    @ToolbarContentBuilder
    private var macAddPetToolbarItem: some ToolbarContent {
        EmptyToolbarContent()
    }
    #endif

    #if os(iOS)
    private var usesFloatingAddPetAction: Bool {
        horizontalSizeClass == .compact
    }

    /// Keep the add-pet action inside the content safe area, above the tab bar.
    /// During the tour only its own step displays it; opacity preserves the anchor.
    private var isAddPetFabHiddenForWalkthrough: Bool {
        !usesFloatingAddPetAction || (walkthrough?.isActive == true && walkthrough?.currentStep?.anchor != .cdAddPet)
    }

    @ViewBuilder
    private var addPetFab: some View {
        let fab = FAB(
            systemImage: "pawprint.fill",
            accessibilityLabel: NSLocalizedString("a11y.add_new_pet", comment: ""),
            tint: DS.ColorToken.primary
        ) {
            sheetDestination = .addPet
        }
        .opacity(isAddPetFabHiddenForWalkthrough ? 0 : 1)
        .allowsHitTesting(!isAddPetFabHiddenForWalkthrough)
        .accessibilityHidden(isAddPetFabHiddenForWalkthrough)
        .accessibilityIdentifier("clientDetail.addPet.floating")
        .animation(.easeInOut(duration: 0.2), value: isAddPetFabHiddenForWalkthrough)

        // Only the *visible* add-pet control may own the `.cdAddPet` spotlight
        // anchor. On regular width (iPad) the inline header "Add Pet" button owns
        // it; if the hidden FAB also registered the anchor, it would win the
        // preference merge and point the spotlight at an empty bottom corner.
        if usesFloatingAddPetAction {
            fab.walkthroughAnchor(.cdAddPet)
        } else {
            fab
        }
    }
    #endif

    private var showsInlineAddPetAction: Bool {
        #if os(iOS)
        !usesFloatingAddPetAction
        #else
        true
        #endif
    }

    @ViewBuilder
    private func destinationSheet(_ destination: SheetDestination, vm: ClientDetailViewModel) -> some View {
        switch destination {
        case .addPet:
            AddPetSheet(client: vm.client)
        case .editPet(let pet):
            EditPetSheet(pet: pet)
        case .editClient:
            EditClientSheet(client: vm.client)
        case .history(let pet):
            PetHistoryView(pet: pet)
        case .communication(let pet):
            CommunicationSheet(pet: pet, visit: nil)
        case .subscriptionPaywall:
            SubscriptionPaywallView()
        }
    }

    private var contactEditorSheet: some View {
        NavigationStack {
            Form {
                Section(editingContact == nil ? NSLocalizedString("client_detail.new_emergency_contact", comment: "") : NSLocalizedString("client_detail.edit_emergency_contact", comment: "")) {
                    TextField(NSLocalizedString("form.name", comment: ""), text: $newContactName)
                        .focused($contactNameFocused)
                        .textLengthLimit($newContactName, to: TextInputLimits.name)
                        .accessibilityIdentifier("contactEditor.name")
                    if let contactNameError {
                        contactFieldError(contactNameError, identifier: "contactEditor.name.error")
                    }
                    TextField(NSLocalizedString("form.relation", comment: ""), text: $newContactRelation)
                        .textLengthLimit($newContactRelation, to: TextInputLimits.shortText)
                    TextField(NSLocalizedString("form.phone", comment: ""), text: $newContactPhone)
                        .phoneFieldFormatting($newContactPhone)
                        .textLengthLimit($newContactPhone, to: TextInputLimits.phone)
                        .accessibilityIdentifier("contactEditor.phone")
                    if let contactPhoneError {
                        contactFieldError(contactPhoneError, identifier: "contactEditor.phone.error")
                    }
                }
                .onChange(of: newContactName) { _, _ in clearContactFieldErrors() }
                .onChange(of: newContactPhone) { _, _ in clearContactFieldErrors() }
            }
            .navigationTitle(editingContact == nil ? NSLocalizedString("client_detail.add_contact", comment: "") : NSLocalizedString("client_detail.edit_contact", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) {
                        clearContactFieldErrors()
                        showContactEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("common.save", comment: "")) { addOrUpdateContact() } }
            }
            .alert(AppLocalization.localized("common.error", value: "Error"), isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
                Button(NSLocalizedString("common.ok", comment: "")) { validationError = nil }
            } message: {
                if let error = validationError {
                    Text(error)
                }
            }
            .task { contactNameFocused = true }
        }
    }

    private func contactFieldError(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(DS.ColorToken.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func clearContactFieldErrors() {
        contactNameError = nil
        contactPhoneError = nil
    }

    private func alertTitleText(for destination: AlertDestination?, vm: ClientDetailViewModel) -> Text {
        switch destination {
        case .checkIn(let pet):
            return Text(String(format: NSLocalizedString("client_details.checkin_confirm_title_fmt", comment: ""), pet.name))
        case .deleteClient:
            return Text(String(format: NSLocalizedString("clients.delete_confirm_title_fmt", comment: ""), vm.client.fullName))
        case .deleteError:
            return Text(NSLocalizedString("clients.delete_failed", comment: ""))
        case .deleteContact:
            return Text(NSLocalizedString("client_detail.delete_contact_title", comment: ""))
        case .inlineEditConflict:
            return Text(AppLocalization.localized("client_edit.conflict.title", value: "Changed on Another Device"))
        case .inlineEditFailed:
            return Text(AppLocalization.localized("common.error", value: "Error"))
        case .none:
            return Text("")
        }
    }

    @ViewBuilder
    private func alertActions(for destination: AlertDestination, vm: ClientDetailViewModel) -> some View {
        switch destination {
        case .checkIn(let pet):
            Button(NSLocalizedString("common.yes", comment: "")) {
                vm.checkIn(pet: pet)
                withAnimation(Animations.fastEaseOut) { showSessionStartedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(Animations.fastEaseOut) { showSessionStartedToast = false }
                }
            }
            Button(NSLocalizedString("common.no", comment: ""), role: .cancel) {}
        case .deleteClient:
            Button(NSLocalizedString("common.yes", comment: ""), role: .destructive) {
                deleteClient(vm: vm)
            }
            Button(NSLocalizedString("common.no", comment: ""), role: .cancel) {}
        case .deleteError:
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        case .deleteContact(let contact):
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                confirmDeleteContact(contact)
            }
            Button(NSLocalizedString("common.cancel", value: "Cancel", comment: ""), role: .cancel) {}
        case .inlineEditConflict:
            Button(AppLocalization.localized("client_edit.conflict.save_mine", value: "Save My Changes")) {
                saveInlineEdit(vm.client, overwrite: true)
            }
            Button(AppLocalization.localized("client_edit.conflict.discard_mine", value: "Discard My Changes"), role: .destructive) {
                cancelInlineEdit(vm.client)
            }
        case .inlineEditFailed:
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func alertMessage(for destination: AlertDestination) -> some View {
        switch destination {
        case .checkIn:
            Text(NSLocalizedString("client_details.checkin_confirm_message", comment: ""))
        case .deleteClient:
            Text(NSLocalizedString("clients.delete_confirm_message", comment: ""))
        case .deleteError(let message):
            Text(message)
        case .deleteContact:
            Text(NSLocalizedString("client_detail.delete_contact_message", comment: ""))
        case .inlineEditConflict(let name):
            Text(String(
                format: AppLocalization.localized(
                    "client_edit.conflict.message_fmt",
                    value: "%@ was changed on another device while you were editing. Save My Changes keeps any fields you didn't edit as the other device left them."
                ),
                name
            ))
        case .inlineEditFailed(let message):
            Text(message)
        }
    }

    private func content(vm: ClientDetailViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // One tour stop covers the profile header and, when a pet
                    // is flagged aggressive, the red Caution banner under it.
                    VStack(spacing: 16) {
                        ownerHeader(client: vm.client, primaryEmergencyContact: vm.primaryEmergencyContact)
                        clientSafetyBanner(client: vm.client)
                    }
                    .walkthroughTarget(.cdOwner)
                    // The card's "+" button carries `.emergencyContactBadges`.
                    emergencyContactsCard(contacts: vm.emergencyContacts)
                        .walkthroughTarget(.cdEmergency)
                    notesCard(client: vm.client)
                    loyaltySection(client: vm.client)
                        .walkthroughTarget(.cdLoyalty)
                    petsSection(vm: vm)
                        .walkthroughTarget(.cdPets)
                    recentHistorySection(vm: vm)
                    metadataFooter(client: vm.client)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: clientDetailContentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .modifier(ClientDetailWalkthroughOverlayModifier(walkthrough: walkthrough, sizeClass: horizontalSizeClass))
            .onAppear {
                scrollToWalkthroughAnchorIfNeeded(walkthrough?.currentStep?.anchor, proxy: proxy)
            }
            .onChange(of: walkthrough?.currentStep?.anchor) { _, anchor in
                scrollToWalkthroughAnchorIfNeeded(anchor, proxy: proxy)
            }
        }
        // Toasts must overlay the full scroll area so they appear at the top of
        // the screen regardless of scroll position. Previously this overlay was
        // attached to `recentHistorySection`, which rendered the toast far below
        // the fold — making the Check In button look like it did nothing.
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if showSessionStartedToast {
                    SessionToast(
                        text: sessionStartedToastText.isEmpty
                            ? NSLocalizedString("client_detail.session_started", comment: "")
                            : sessionStartedToastText,
                        tint: .blue
                    )
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if showSavedToast {
                    SavedToast(text: NSLocalizedString("client_detail.saved_successfully", comment: ""))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clientDidCreate)) { notif in
            guard let id = notif.createdClientID, notif.clientCreatePhase == .navigated else { return }
            if id == vm.client.persistentModelID {
                withAnimation(Animations.fastEaseOut) { showSavedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(Animations.fastEaseOut) { showSavedToast = false }
                }
            }
        }
    }

    private func loyaltySection(client: Client) -> some View {
        Card(elevation: .flat, hoverRaises: false) {
            Group {
                if entitlements.isPremium {
                    Button {
                        router.navigateToClientLoyalty(client)
                    } label: {
                        loyaltyRowContent(client: client, isLocked: false)
                    }
                    .buttonStyle(.plain)
                    .pressScaleStyle(hapticsEnabled: true)
                } else {
                    Button {
                        sheetDestination = .subscriptionPaywall
                    } label: {
                        loyaltyRowContent(client: client, isLocked: true)
                    }
                    .buttonStyle(.plain)
                    .pressScaleStyle(hapticsEnabled: true)
                }
            }
            .accessibilityIdentifier("clientDetail.loyaltyRewards")
        }
        .padding(.horizontal)
        .task(id: loyaltyBalance.points) {
            do {
                let options = try await LoyaltyService(modelContainer: modelContext.container).checkoutOptions(clientUUID: client.uuid)
                profileRewards = options.rewards.sorted { $0.pointCost < $1.pointCost }
            } catch {
                profileRewards = []
                Logger.clientDetailView.error("Reward availability failed: \(error.localizedDescription)")
            }
        }
    }

    private func loyaltyRowContent(client: Client, isLocked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isLocked ? "lock" : "sparkles")
                .font(.headline)
                .foregroundStyle(DS.ColorToken.primary)
                .frame(width: 44, height: 44)
                .background(DS.ColorToken.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.localized("client_detail.loyalty.title", value: "Loyalty & Rewards"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(isLocked
                     ? AppLocalization.localized("client_detail.loyalty.locked_subtitle", value: "Premium client retention tools")
                     : AppLocalization.localized("client_detail.loyalty.subtitle", value: "Points saved automatically from paid visits"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isLocked, let reward = profileRewards.last(where: { $0.isRedeemable(with: loyaltyBalance.points) }) {
                    Text(LoyaltyRewardCatalog.displayTitle(for: reward) + " · " + AppLocalization.localized("checkout.loyalty.ready", value: "Ready to redeem"))
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                }
            }

            Spacer(minLength: 8)

            LoyaltyPointsBadge(client: client, scale: .compact, balanceOverride: loyaltyBalance.points, errorMessage: loyaltyBalance.errorMessage)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            format: isLocked
                ? AppLocalization.localized("client_detail.loyalty.locked_accessibility_fmt", value: "Loyalty and rewards locked, %d points")
                : AppLocalization.localized("client_detail.loyalty.accessibility_fmt", value: "Loyalty and rewards, %d points"),
            loyaltyBalance.points
        ))
    }

    private var clientDetailContentMaxWidth: CGFloat {
        #if os(macOS)
        return 1180
        #else
        return horizontalSizeClass == .compact ? 640 : 1100
        #endif
    }

    private func scrollToWalkthroughAnchorIfNeeded(_ anchor: WalkthroughAnchorID?, proxy: ScrollViewProxy) {
        guard let anchor, Self.walkthroughAnchors.contains(anchor) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard walkthrough?.currentStep?.anchor == anchor else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
    }

    private func metadataFooter(client: Client) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: NSLocalizedString("common.updated_fmt", value: "Updated %@", comment: ""), client.updatedAt.formatted(date: .abbreviated, time: .shortened)))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Subviews
    private func ownerHeader(client: Client, primaryEmergencyContact: EmergencyContact?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.fullName)
                            .font(.title3.weight(.semibold))
                            .matchedGeometryEffect(id: "name-\(client.id)", in: namespace)
                        Text(String(format: NSLocalizedString("client_detail.client_since_fmt", comment: ""), Formatters.monthYear.string(from: client.createdAt)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isEditingClientInline {
                        HStack(spacing: 8) {
                            Button { cancelInlineEdit(client) } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityIdentifier("clientDetail.inlineEdit.cancel")
                            Button { saveInlineEdit(client) } label: { Image(systemName: "checkmark.circle.fill") }
                                .disabled(
                                    editFirst.trimmed.isEmpty ||
                                    editLast.trimmed.isEmpty ||
                                    inlineEditForm.proposedFields(original: (inlineEditBaseline ?? ClientEditBaseline(client)).fields) == nil
                                )
                                .accessibilityIdentifier("clientDetail.inlineEdit.save")
                        }
                        .font(.title3)
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                guard let firstPet = (client.pets ?? []).first else { return }
                                viewModel?.recordAttentionOutreach(method: "message")
                                // Route through the single `.sheet(item:)` so the
                                // template picker presents on macOS too — a separate
                                // `.sheet(isPresented:)` on the outer Group was being
                                // silently dropped by SwiftUI on macOS.
                                sheetDestination = .communication(firstPet)
                            } label: { Image(systemName: "message.circle.fill") }
                                .font(.title3)
                                .foregroundStyle(DS.ColorToken.calmBlue)
                                .disabled((client.pets ?? []).isEmpty)
                                .accessibilityLabel(
                                    NSLocalizedString("client_detail.message", value: "Message", comment: "")
                                )
                                .accessibilityIdentifier("clientDetail.message")
                            Button { beginInlineEdit(client) } label: { Image(systemName: "ellipsis.circle") }
                                .font(.title3)
                                .accessibilityLabel(NSLocalizedString("a11y.more_actions", comment: ""))
                                .accessibilityIdentifier("clientDetail.editInline")
                        }
                    }
                }

                if isEditingClientInline {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField(NSLocalizedString("new_client.first_name", comment: ""), text: $editFirst)
                                .textFieldStyle(.roundedBorder)
                                .textLengthLimit($editFirst, to: TextInputLimits.name)
                            TextField(NSLocalizedString("new_client.last_name", comment: ""), text: $editLast)
                                .textFieldStyle(.roundedBorder)
                                .textLengthLimit($editLast, to: TextInputLimits.name)
                        }
                        HStack {
                            TextField(NSLocalizedString("new_client.phone", comment: ""), text: $editPhone)
                                .textFieldStyle(.roundedBorder)
                                .phoneFieldFormatting($editPhone)
                                .textLengthLimit($editPhone, to: TextInputLimits.phone)
                            TextField(NSLocalizedString("new_client.email", comment: ""), text: $editEmail)
                                .textFieldStyle(.roundedBorder)
                                .textLengthLimit($editEmail, to: TextInputLimits.email)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        contactRow(
                            icon: "phone.fill",
                            tint: DS.ColorToken.success,
                            text: PhoneUtils.display(client.phone ?? "") ?? "—"
                        ) {
                            if let tel = PhoneUtils.telURLString(client.phone ?? ""), let url = URL(string: tel) {
                                viewModel?.recordAttentionOutreach(method: "call")
                                URLOpener.open(url)
                            }
                        } trailing: {
                            HStack(spacing: 8) {
                                if PhoneUtils.smsURLString(client.phone ?? "") != nil {
                                    Button {
                                        guard let firstPet = (client.pets ?? []).first else { return }
                                        sheetDestination = .communication(firstPet)
                                    } label: { Image(systemName: "message.fill") }
                                    .foregroundStyle(DS.ColorToken.success)
                                    .accessibilityLabel(NSLocalizedString("client_detail.message", value: "Message", comment: ""))
                                }
                                if let tel = PhoneUtils.telURLString(client.phone ?? ""), let telURL = URL(string: tel) {
                                    Button {
                                        viewModel?.recordAttentionOutreach(method: "call")
                                        URLOpener.open(telURL)
                                    } label: { Image(systemName: "phone.fill") }
                                    .foregroundStyle(DS.ColorToken.success)
                                    .accessibilityLabel(
                                        NSLocalizedString("client_detail.call", value: "Call", comment: "")
                                    )
                                }
                            }
                        }
                        contactRow(icon: "envelope.fill", tint: DS.ColorToken.calmBlue, text: (client.email ?? "—")) {
                            if let email = client.email, let url = URL(string: "mailto:\(email)") { URLOpener.open(url) }
                        } trailing: {
                            if let email = client.email, let url = URL(string: "mailto:\(email)") {
                                Button { URLOpener.open(url) } label: { Image(systemName: "envelope.fill") }
                                    .foregroundStyle(DS.ColorToken.calmBlue)
                                    .accessibilityLabel(
                                        NSLocalizedString("client_detail.email", value: "Email", comment: "")
                                    )
                            }
                        }
                        contactRow(
                            icon: "mappin.and.ellipse",
                            tint: DS.ColorToken.warning,
                            text: client.address ?? "—"
                        ) {} trailing: {
                            if let addr = client.address?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "http://maps.apple.com/?q=\(addr)") {
                                Button { URLOpener.open(url) } label: { Image(systemName: "map.fill") }
                                    .foregroundStyle(DS.ColorToken.warning)
                                    .accessibilityLabel(
                                        NSLocalizedString("client_detail.directions", value: "Directions", comment: "")
                                    )
                            }
                        }
                        if let primaryEmergencyContact {
                            primaryEmergencyContactRow(primaryEmergencyContact)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// "Emergency: Maria (sister) · (555) 123-4567" under the owner's own
    /// contact rows, so staff reach the backup person without scrolling to
    /// the full card further down.
    private func primaryEmergencyContactRow(_ contact: EmergencyContact) -> some View {
        let summary = EmergencyContactRules.summaryLine(name: contact.name, relation: contact.relation, phone: contact.phone)
        let text = String(
            format: AppLocalization.localized("client_detail.emergency_primary_fmt", value: "Emergency: %@"),
            summary
        )
        let telURL = PhoneUtils.telURLString(contact.phone).flatMap { URL(string: $0) }
        return contactRow(icon: "cross.fill", tint: DS.ColorToken.danger, filledIcon: true, text: text) {
            if let telURL { URLOpener.open(telURL) }
        } trailing: {
            #if os(macOS)
            if !contact.phone.trimmed.isEmpty {
                Button { PasteboardWriter.copy(EmergencyContactRules.displayPhone(contact.phone)) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppLocalization.localized("client_detail.copy_phone", value: "Copy Phone"))
            }
            #endif
            if let telURL {
                Button { URLOpener.open(telURL) } label: { Image(systemName: "phone.fill") }
                    .foregroundStyle(DS.ColorToken.success)
                    .accessibilityLabel(String(
                        format: AppLocalization.localized("client_detail.call_contact_fmt", value: "Call %@"),
                        contact.name
                    ))
            }
        }
        .accessibilityIdentifier("clientDetail.primaryEmergencyContact")
    }

    @ViewBuilder
    private func notesCard(client: Client) -> some View {
        if let notes = client.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("client_detail.notes", comment: "")).font(.headline)
                    Text(notes.trimmingCharacters(in: .whitespacesAndNewlines)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.yellow.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func emergencyContactsCard(contacts: [EmergencyContact]) -> some View {
        EmergencyContactSummaryCard(
            contacts: contacts,
            ownerPhone: client.phone,
            ownerEmail: client.email,
            onAdd: {
                editingContact = nil
                newContactName = ""
                newContactRelation = ""
                newContactPhone = ""
                clearContactFieldErrors()
                showContactEditor = true
            },
            onEdit: { contact in
                beginEditContact(contact)
            },
            onDelete: { contact in
                alertDestination = .deleteContact(contact)
            }
        )
        .padding(.horizontal)
    }

    private func confirmDeleteContact(_ contact: EmergencyContact) {
        let context = contact.modelContext ?? modelContext
        context.delete(contact)
        do {
            try context.save()
            NotificationCenter.default.post(name: .clientDidUpdate, object: nil)
        } catch {
            Logger.clientDetailView.error("Failed to delete contact: \(error.localizedDescription, privacy: .public)")
            Logger.database.error("Local save failed: \(error.localizedDescription, privacy: .public)")
        }
        viewModel?.refreshEmergencyContacts()
    }

    private func addOrUpdateContact() {
        guard let vm = viewModel else { return }
        clearContactFieldErrors()
        let result = vm.saveEmergencyContact(
            editing: editingContact,
            name: newContactName,
            relation: newContactRelation,
            phone: newContactPhone
        )
        switch result {
        case .saved, .unchanged:
            showContactEditor = false
            editingContact = nil
            newContactName = ""; newContactRelation = ""; newContactPhone = ""
        case .invalid(.name, let message):
            contactNameError = message
            HapticManager.notify(.error)
        case .invalid(.phone, let message):
            contactPhoneError = message
            HapticManager.notify(.error)
        case .failed(let message):
            validationError = message
        }
    }

    private func beginEditContact(_ c: EmergencyContact) {
        // Re-read first so the editor starts from what the store has, not
        // from values this context kept after another device's change.
        viewModel?.refreshEmergencyContacts()
        editingContact = c
        newContactName = TextInputLimits.limited(c.name, to: TextInputLimits.name)
        newContactRelation = TextInputLimits.limited(c.relation ?? "", to: TextInputLimits.shortText)
        newContactPhone = TextInputLimits.limited(PhoneUtils.display(c.phone) ?? c.phone, to: TextInputLimits.phone)
        clearContactFieldErrors()
        showContactEditor = true
    }

    // MARK: - Safety (Aggressive behavior)

    /// Prominent, high-visibility warning shown at the top of the client center
    /// whenever any of the client's pets is flagged aggressive — so staff see
    /// the hazard before touching the dog.
    @ViewBuilder
    private func clientSafetyBanner(client: Client) -> some View {
        let aggressivePets = (client.pets ?? []).filter { $0.archivedAt == nil && $0.isAggressive }
        if !aggressivePets.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("client_detail.safety_alert.title", value: "Caution: Aggressive Behavior", comment: ""))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(safetyBannerMessage(for: aggressivePets))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.ColorToken.danger, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("clientDetail.safetyBanner")
        }
        let carePets = (client.pets ?? []).filter { $0.archivedAt == nil && $0.hasSpecialNeeds }
        if !carePets.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cross.case.fill").font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.localized("client_detail.special_needs.title", value: "Priority: Special Needs"))
                        .font(.subheadline.weight(.bold))
                    Text(String(format: AppLocalization.localized("client_detail.special_needs.message_fmt", value: "%@ needs priority care. Review care notes and adapt handling, comfort, and timing."), carePets.map(\.name).joined(separator: ", ")))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BehaviorTagIcons.tint(for: .specialNeeds), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("clientDetail.specialNeedsBanner")
        }
    }

    private func safetyBannerMessage(for aggressivePets: [Pet]) -> String {
        if aggressivePets.count == 1, let pet = aggressivePets.first {
            let status = pet.aggressionClearanceStatus
            if status.isProbationary {
                return String(
                    format: NSLocalizedString(
                        "client_detail.safety_alert.probation_fmt",
                        value: "%@ is flagged aggressive (%d/3 visits without aggression completed). Alert the team and handle with care.",
                        comment: ""
                    ),
                    pet.name,
                    status.calmStreak
                )
            } else {
                return String(
                    format: NSLocalizedString(
                        "client_detail.safety_alert.message_fmt",
                        value: "%@ is flagged as aggressive. Alert the team and handle with care.",
                        comment: ""
                    ),
                    pet.name
                )
            }
        } else {
            return String(
                format: NSLocalizedString(
                    "client_detail.safety_alert.message_fmt",
                    value: "%@ is flagged as aggressive. Alert the team and handle with care.",
                    comment: ""
                ),
                aggressivePets.map(\.name).joined(separator: ", ")
            )
        }
    }

    /// Red safety flag rendered on an aggressive pet's row in the pet list.
    /// Shows clearance progress if pet is on probation (e.g. 1/3 or 2/3 visits without aggression).
    private func aggressivePetBadge(for pet: Pet) -> some View {
        let status = pet.aggressionClearanceStatus
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            if status.isProbationary {
                Text(String(
                    format: NSLocalizedString("pet.safety.probation_badge_fmt", value: "Aggressive — %d/3 visits without aggression to clear", comment: ""),
                    status.calmStreak
                ))
                .font(.caption2.weight(.bold))
                HStack(spacing: 3) {
                    ForEach(0..<status.requiredStreak, id: \.self) { index in
                        Circle()
                            .fill(index < status.calmStreak ? Color.green : Color.white.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                }
            } else {
                Text(NSLocalizedString("pet.safety.aggressive_badge", value: "Aggressive — handle with care", comment: ""))
                    .font(.caption2.weight(.bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(DS.ColorToken.danger, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(
            status.isProbationary
                ? String(format: NSLocalizedString("pet.safety.probation_a11y_fmt", value: "Warning: this pet is marked aggressive, %d of 3 visits without aggression to clear.", comment: ""), status.calmStreak)
                : NSLocalizedString("pet.safety.aggressive_a11y", value: "Warning: this pet is marked aggressive. Handle with care.", comment: "")
        )
        .accessibilityIdentifier("pet.aggression.priorityBadge")
    }

    private func petsSection(vm: ClientDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(String(format: NSLocalizedString("client_detail.pets_count_fmt", comment: ""), vm.pets.count))
                    .font(.headline)
                Spacer(minLength: 12)
                if showsInlineAddPetAction {
                    Button {
                        sheetDestination = .addPet
                    } label: {
                        Label(NSLocalizedString("client_detail.add_pet", value: "Add Pet", comment: ""), systemImage: "pawprint.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .walkthroughTarget(.cdAddPet)
                    .accessibilityIdentifier("clientDetail.addPet.inline")
                }
            }
            .padding(.horizontal)
            let tourPets = walkthroughAnchorPets(vm: vm)
            VStack(spacing: 12) {
                ForEach(vm.pets) { pet in
                    let activeVisit = vm.activeVisit(for: pet)
                    let isCheckingIn = vm.isCheckingIn(pet)
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(.pet(species: pet.species, gender: pet.gender, name: pet.name, imageData: pet.photoData), size: .md, ringWidth: 3)
                            VStack(alignment: .leading, spacing: 6) {
                                if pet.isAggressive { aggressivePetBadge(for: pet) }
                                if pet.hasSpecialNeeds { SpecialNeedsPetBadge() }
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        PetGenderNameBadge(pet: pet, maxNameWidth: 220)
                                            .walkthroughTarget(.petGenderDots, isActive: pet.persistentModelID == tourPets.featured)
                                        Text(pet.shortDescriptor).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    petStatusPill(activeVisit)
                                    Button {
                                        sheetDestination = .editPet(pet)
                                    } label: { Image(systemName: "pencil") }
                                    .pressScaleStyle()
                                    .accessibilityLabel(AppLocalization.localized("pet.editor.title", value: "Edit Pet"))
                                    .accessibilityIdentifier("clientDetail.pet.\(pet.name).edit")
                                }
                                PetMilestoneView(pet: pet)
                                PetGroomingSignals(pet: pet)
                                HStack(spacing: 8) {
                                    actionButton(title: NSLocalizedString("client_detail.check_in", comment: ""), systemImage: "play.fill", tint: .blue) {
                                        if activeVisit != nil {
                                            sessionStartedToastText = String(
                                                format: AppLocalization.localized("client_detail.pet_already_in_session", value: "%@ is already in session"),
                                                pet.name
                                            )
                                            withAnimation(Animations.fastEaseOut) { showSessionStartedToast = true }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                                withAnimation(Animations.fastEaseOut) { showSessionStartedToast = false }
                                            }
                                            HapticManager.notify(.warning)
                                            return
                                        }
                                        vm.checkIn(pet: pet)
                                        sessionStartedToastText = NSLocalizedString(
                                            "client_detail.session_started",
                                            value: "Session started for \(pet.name)",
                                            comment: ""
                                        )
                                        withAnimation(Animations.fastEaseOut) { showSessionStartedToast = true }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                            withAnimation(Animations.fastEaseOut) { showSessionStartedToast = false }
                                        }
                                    }
                                    .opacity(activeVisit == nil && !isCheckingIn ? 1.0 : 0.55)
                                    .disabled(activeVisit != nil || isCheckingIn)
                                    .id("clientDetail.pet.\(pet.uuid.uuidString).checkIn.\(activeVisit == nil && !isCheckingIn)")
                                    .accessibilityIdentifier("clientDetail.pet.\(pet.name).checkIn")
                                    .walkthroughTarget(.cdCheckIn, isActive: pet.persistentModelID == tourPets.checkIn)

                                    actionButton(title: NSLocalizedString("client_detail.check_out", comment: ""), systemImage: "stop.fill", tint: .blue) {
                                        if let visit = vm.activeVisit(for: pet) {
                                            checkoutRoute = ClientCheckoutRoute(pet: pet, visit: visit)
                                            advanceWalkthroughIntoCheckoutIfNeeded()
                                            HapticManager.play(.navigation)
                                        } else {
                                            vm.refreshPets()
                                            HapticManager.notify(.warning)
                                        }
                                    }
                                    .opacity(activeVisit == nil ? 0.65 : 1.0)
                                    .disabled(activeVisit == nil)
                                    .id("clientDetail.pet.\(pet.uuid.uuidString).checkOut.\(activeVisit != nil)")
                                    .accessibilityIdentifier("clientDetail.pet.\(pet.name).checkOut")
                                    .walkthroughTarget(.cdCheckOut, isActive: pet.persistentModelID == tourPets.featured)

                                    actionButton(title: NSLocalizedString("client_detail.history", comment: ""), systemImage: "clock.arrow.circlepath", borderOnly: true) {
                                        sheetDestination = .history(pet)
                                    }
                                    .id("clientDetail.pet.\(pet.uuid.uuidString).history")
                                    .accessibilityIdentifier("clientDetail.pet.\(pet.name).history")
                                    .walkthroughTarget(.cdPetHistory, isActive: pet.persistentModelID == tourPets.featured)
                                }
                            }
                        }
                    }
                    .petBehaviorAura(pet: pet)
                    .animation(MotionSystem.resolved(MotionSystem.fluid, reduceMotion: reduceMotion), value: pet.behaviorTagsRaw)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .buttonStyle(.plain)
                }
                // ForEach compares model IDs, not which ModelContext owns the objects.
                // A new committed presentation graph must rebuild its display closures.
                .id(vm.petPresentationRevision)
            }
            .animation(MotionSystem.resolved(MotionSystem.fluid, reduceMotion: reduceMotion), value: vm.pets.map(\.uuid))
            .padding(.horizontal)
            let removedPets = (vm.client.pets ?? []).filter { $0.archivedAt != nil }
            if !removedPets.isEmpty {
                DisclosureGroup(AppLocalization.localized("pet.editor.removed", value: "Removed Pets")) {
                    ForEach(removedPets, id: \.uuid) { pet in
                        HStack {
                            Text(pet.name)
                            Spacer()
                            Button(AppLocalization.localized("pet.editor.title", value: "Edit Pet")) {
                                sheetDestination = .editPet(pet)
                            }
                            .pressScaleStyle()
                            .accessibilityLabel(AppLocalization.localized("pet.editor.title", value: "Edit Pet"))
                            Button(AppLocalization.localized("client_detail.history", value: "History")) {
                                sheetDestination = .history(pet)
                            }
                            .pressScaleStyle()
                            .accessibilityLabel(AppLocalization.localized("client_detail.history", value: "History"))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func recentHistorySection(vm: ClientDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(NSLocalizedString("client_details.recent_history", comment: "")).font(.headline)
                Spacer()
                Picker(NSLocalizedString("client_detail.history_range", value: "History range", comment: ""), selection: Binding(
                    get: { vm.historyRange },
                    set: {
                        vm.historyRange = $0
                        walkthrough?.observe(.historyRangeChanged)
                    }
                )) {
                    ForEach(ClientDetailViewModel.HistoryRange.pickerOptions, id: \.self) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.primary)
                // A segmented picker shows its title beside the segments on
                // macOS, which read as a second "All" next to [All | Last 90 Days].
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            .padding(.horizontal)
            .walkthroughTarget(.cdHistory)

            if vm.recentVisits.isEmpty {
                ContentUnavailableView(NSLocalizedString("client_detail.no_history_yet", comment: ""), systemImage: "clock.badge.questionmark")
                    .padding(.vertical, 20)
            } else {
                // Group by day to mirror the sample design
                let grouped = Dictionary(grouping: vm.recentVisits) { Calendar.current.startOfDay(for: $0.sortKeyDate) }
                let orderedDays = grouped.keys.sorted(by: >)
                // The newest visit: the Academy's "open a visit" stop points here.
                let tourVisitID = orderedDays.first.flatMap { day in
                    (grouped[day] ?? []).max(by: { $0.sortKeyDate < $1.sortKeyDate })?.id
                }
                VStack(spacing: 14) {
                    ForEach(orderedDays, id: \.self) { day in
                        let visits = (grouped[day] ?? []).sorted(by: { $0.sortKeyDate > $1.sortKeyDate })
                        HStack(spacing: 6) {
                            Text(Formatters.dateOnly.string(from: day)).font(.subheadline.weight(.semibold))
                            Text(String(format: NSLocalizedString("client_detail.visits_count_fmt", comment: ""), visits.count))
                                .font(.caption.weight(.bold))
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(Capsule().fill(Color.gray.opacity(0.15)))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(visits) { visit in
                            Button(action: {
                                router.navigateToVisit(visit)
                                walkthrough?.observe(.visitOpened)
                            }) {
                                CardFactory.makeVisitTimelineRow(visit: visit)
                            }
                            .buttonStyle(.plain)
                            .walkthroughTarget(.cdVisitRow, isActive: visit.id == tourVisitID)
                        }
                    }
                    if vm.canLoadMore {
                        Button {
                            vm.loadMore()
                        } label: {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(NSLocalizedString("common.load_more", comment: "Load More"))
                                    .font(.footnote.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 80) // space for FAB
    }

    // MARK: - Toolbar
    @State private var isDeleting = false
    
    @ToolbarContentBuilder
    private func toolbarContent(_ vm: ClientDetailViewModel) -> some ToolbarContent {
        // Rely on the system-provided back button to avoid duplicates
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                alertDestination = .deleteClient
            } label: {
                if isDeleting {
                    ProgressView()
                } else {
                    Image(systemName: "trash")
                }
            }
            .disabled(isDeleting)
            .accessibilityLabel(NSLocalizedString("client_details.delete", comment: ""))
            .accessibilityIdentifier("clientDetail.toolbar.delete")
            .tint(.red)
        }
    }

    // MARK: - Actions

    private func deleteClient(vm: ClientDetailViewModel) {
        Task { await performDeleteClient(vm: vm) }
    }

    @MainActor
    private func performDeleteClient(vm: ClientDetailViewModel) async {
        isDeleting = true

        let client = vm.client
        let modelContext = client.modelContext ?? modelContext
        // Gather affected dates before deletion for summary updates
        let clientUUID = client.uuid
        let pets = client.pets ?? []
        let petUUIDs = pets.map(\.uuid)
        let visits = pets.flatMap { $0.visits ?? [] }
        let paymentDates = visits.compactMap { $0.payment?.paidAt }
        let visitActivityDates = visits.map { $0.endedAt ?? $0.startedAt }

        // Delete the client; cascade rules will handle pets, visits, items, payments, and contacts.
        modelContext.delete(client)

        do {
            try modelContext.save()
            SpotlightIndexer.shared.removeClientAndPetsFromIndex(clientID: clientUUID, petIDs: petUUIDs)

            // Rebuild summaries for affected days
            let cal = Calendar.current
            var affectedDays: Set<Date> = []
            for date in paymentDates { affectedDays.insert(cal.startOfDay(for: date)) }
            for date in visitActivityDates { affectedDays.insert(cal.startOfDay(for: date)) }
            
            for day in affectedDays {
                SummaryUpdater.rebuildDay(for: day, in: modelContext)
                await Task.yield() // Yield to keep UI responsive
            }

            isDeleting = false
            dismiss()
        } catch {
            isDeleting = false
            let message = String(describing: error)
            Logger.clientDetailView.error("Failed to delete client: \(message, privacy: .public)")
            Logger.database.error("Local save failed: \(error.localizedDescription, privacy: .public)")
            alertDestination = .deleteError(message)
        }
    }

    private func beginInlineEdit(_ client: Client) {
        ClientEditSaver.refresh(client)
        let opened = ClientEditBaseline(client)
        inlineEditBaseline = opened
        editFirst = TextInputLimits.limited(opened.fields.firstName, to: TextInputLimits.name)
        editLast = TextInputLimits.limited(opened.fields.lastName, to: TextInputLimits.name)
        editPhone = TextInputLimits.limited(ClientContactFields.formPhoneText(opened.fields.phone), to: TextInputLimits.phone)
        editEmail = TextInputLimits.limited(opened.fields.email ?? "", to: TextInputLimits.email)
        withAnimation(Animations.fastEaseOut) { isEditingClientInline = true }
    }

    private func cancelInlineEdit(_ client: Client) {
        inlineEditBaseline = nil
        withAnimation(Animations.fastEaseOut) { isEditingClientInline = false }
    }

    /// The inline edit has no address field, so the stored address is kept.
    private var inlineEditForm: ClientEditForm {
        ClientEditForm(firstName: editFirst, lastName: editLast, phone: editPhone, email: editEmail, address: nil)
    }

    private func saveInlineEdit(_ client: Client, overwrite: Bool = false) {
        guard let baseline = inlineEditBaseline else { return }
        let outcome = ClientEditSaver.save(
            inlineEditForm,
            baseline: baseline,
            container: modelContext.container,
            refreshing: client.modelContext ?? modelContext,
            overwrite: overwrite
        )
        switch outcome {
        case .saved:
            break
        case .unchanged:
            cancelInlineEdit(client)
            return
        case .changedElsewhere:
            let name = [baseline.fields.firstName, baseline.fields.lastName]
                .map(\.trimmed)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            alertDestination = .inlineEditConflict(
                name: name.isEmpty ? AppLocalization.localized("client_edit.conflict.this_client", value: "This client") : name
            )
            return
        case .invalidPhone:
            return
        case .missing:
            alertDestination = .inlineEditFailed(AppLocalization.localized(
                "client_edit.missing",
                value: "This client is no longer on this device, so your changes weren't saved."
            ))
            return
        case .failed(let message):
            alertDestination = .inlineEditFailed(String(
                format: AppLocalization.localized("common.save_failed", value: "Save failed. Please try again.\n\n%@"),
                message
            ))
            return
        }
        inlineEditBaseline = nil
        withAnimation(Animations.fastEaseOut) { isEditingClientInline = false }
        // Optional: show a small saved toast for inline edits
        withAnimation(Animations.fastEaseOut) { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(Animations.fastEaseOut) { showSavedToast = false }
        }
    }

    private func continueWalkthroughAfterVisitStart(_ notification: Notification, vm: ClientDetailViewModel) {
        // Explain-only steps (a salon with real clients) move on with Next,
        // never because a visit started.
        guard walkthrough?.isActive == true,
              walkthrough?.currentStep?.anchor == .cdCheckIn,
              walkthrough?.currentStep?.requiresTargetAction == true
        else { return }

        guard let visit = notification.object as? Visit,
              let petID = visit.pet?.persistentModelID,
              vm.pets.contains(where: { $0.persistentModelID == petID })
        else { return }

        vm.refreshPets()
        vm.refreshRecentVisits()
        walkthrough?.advance()
    }

    /// Every pet already in session: nothing is left to check in, so the
    /// hands-on Check In stop shows Next instead of waiting for a tap, in
    /// either direction. The stop isn't skipped, so its explanation stays
    /// readable.
    private func releaseWalkthroughCheckInIfAlreadyInSession(vm: ClientDetailViewModel) {
        // Only a hands-on step waits for a check-in. An explain-only one
        // already shows Next.
        guard walkthrough?.isActive == true,
              walkthrough?.currentStep?.anchor == .cdCheckIn,
              walkthrough?.currentStep?.requiresTargetAction == true
        else { return }

        vm.refreshPets()
        // Still a real mission while some pet is waiting to be checked in.
        guard !vm.pets.isEmpty, vm.pets.allSatisfy({ vm.activeVisit(for: $0) != nil }) else { return }
        walkthrough?.releaseActionRequirement(reason: "every pet is already checked in")
    }

    /// Check Out can't be tapped without a pet in session. Show Next rather
    /// than wait for a tap that can't happen.
    private func releaseWalkthroughCheckOutIfNothingIsCheckedIn(vm: ClientDetailViewModel) {
        guard walkthrough?.isActive == true,
              walkthrough?.currentStep?.anchor == .cdCheckOut,
              walkthrough?.currentStep?.requiresTargetAction == true
        else { return }
        vm.refreshPets()
        if firstActiveCheckoutRoute(vm: vm) == nil {
            walkthrough?.releaseActionRequirement(reason: "no pet is checked in")
        }
    }

    /// The tour's "+" stop moves on once the emergency contact form it
    /// opened is closed, whether a contact was saved or not.
    private func continueWalkthroughAfterContactEditor(isShowing: Bool) {
        if isShowing {
            walkthroughOpenedContactEditor = walkthrough?.currentStep?.advancesOn == .emergencyContactEditorClosed
        } else if walkthroughOpenedContactEditor {
            walkthroughOpenedContactEditor = false
            walkthrough?.observe(.emergencyContactEditorClosed)
        }
    }

    /// The pets the tour's per-pet stops point at, one each: Check In on a
    /// pet that isn't in session, the rest on the pet in session (checkout
    /// opens its visit), else the first pet.
    private func walkthroughAnchorPets(vm: ClientDetailViewModel) -> (featured: PersistentIdentifier?, checkIn: PersistentIdentifier?) {
        let inSession = vm.pets.first { vm.activeVisit(for: $0) != nil }
        let waiting = vm.pets.first { vm.activeVisit(for: $0) == nil }
        return (
            featured: (inSession ?? vm.pets.first)?.persistentModelID,
            checkIn: (waiting ?? vm.pets.first)?.persistentModelID
        )
    }

    private func advanceWalkthroughIntoCheckoutIfNeeded() {
        guard walkthrough?.isActive == true,
              walkthrough?.currentStep?.anchor == .cdCheckOut
        else { return }

        isWalkthroughDrivingCheckout = true
        walkthrough?.advance()
    }

    private func synchronizeWalkthroughCheckoutPresentation(_ presentation: WalkthroughPresentation?, vm: ClientDetailViewModel) {
        guard walkthrough?.isActive == true else {
            closeWalkthroughCheckoutIfNeeded()
            return
        }

        if presentation == .checkout {
            openWalkthroughCheckoutIfPossible(vm: vm)
        } else {
            closeWalkthroughCheckoutIfNeeded()
        }
    }

    private func openWalkthroughCheckoutIfPossible(vm: ClientDetailViewModel) {
        if checkoutRoute != nil {
            isWalkthroughDrivingCheckout = true
            return
        }

        vm.refreshPets()
        guard let route = firstActiveCheckoutRoute(vm: vm) else { return }
        checkoutRoute = route
        isWalkthroughDrivingCheckout = true
    }

    private func closeWalkthroughCheckoutIfNeeded() {
        guard isWalkthroughDrivingCheckout else { return }
        checkoutRoute = nil
        isWalkthroughDrivingCheckout = false
    }

    private func firstActiveCheckoutRoute(vm: ClientDetailViewModel) -> ClientCheckoutRoute? {
        for pet in vm.pets {
            if let visit = vm.activeVisit(for: pet) {
                return ClientCheckoutRoute(pet: pet, visit: visit)
            }
        }
        return nil
    }

    @State private var showSavedToast = false
    @State private var showSessionStartedToast = false
    @State private var sessionStartedToastText: String = ""

    private struct SavedToast: View {
        var text: String
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
                Text(text).foregroundStyle(.white)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.green.opacity(0.9)))
            .shadow(radius: 6)
        }
    }

    private struct SessionToast: View {
        let text: String
        let tint: Color
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.white)
                Text(text).foregroundStyle(.white)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Capsule().fill(tint.opacity(0.9)))
            .shadow(radius: 6)
        }
    }
}

private struct EmptyToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) { }
    }
}

private struct ClientDetailWalkthroughOverlayModifier: ViewModifier {
    let walkthrough: WalkthroughController?
    let sizeClass: UserInterfaceSizeClass?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if let walkthrough, sizeClass != .compact {
            content.walkthroughOverlay(walkthrough, scope: .detailContent)
        } else {
            content
        }
        #else
        if let walkthrough {
            content.walkthroughOverlay(walkthrough, scope: .detailContent)
        } else {
            content
        }
        #endif
    }
}

private struct CheckoutPresentationModifier: ViewModifier {
    @Binding var checkoutRoute: ClientCheckoutRoute?
    let vm: ClientDetailViewModel
    /// Forwarded so the in-checkout guided-tour overlay renders: SwiftUI does not
    /// reliably propagate `.environment(walkthrough)` into a cover/sheet, so we
    /// re-inject it onto the presented `CheckoutView` below.
    let walkthrough: WalkthroughController?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.adaptiveCover(item: $checkoutRoute) { route in
            checkoutContent(for: route)
        }
        #else
        content.sheet(item: $checkoutRoute) { route in
            checkoutContent(for: route)
        }
        #endif
    }

    @ViewBuilder
    private func checkoutContent(for route: ClientCheckoutRoute) -> some View {
        CheckoutView(pet: route.pet, visit: route.visit)
            .environment(walkthrough)
            .onDisappear {
                vm.refreshPets()
                vm.refreshRecentVisits()
            }
    }
}

// MARK: - Local UI building blocks

private struct InitialsCircle: View {
    let initials: String
    var gradient: Gradient = Gradient(colors: [Color.blue, Color.blue.opacity(0.85)])
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(gradient: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials).font(.headline.weight(.semibold)).foregroundStyle(.primary)
        }
    }
}

@ViewBuilder private func contactRow(
    icon: String,
    tint: Color,
    filledIcon: Bool = false,
    text: String,
    onTap: @escaping () -> Void,
    @ViewBuilder trailing: () -> some View
) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filledIcon ? .white : tint)
            .frame(width: 28, height: 28)
            .background(filledIcon ? tint : tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
        Text(text).font(.subheadline.weight(.medium))
        Spacer()
        HStack(spacing: 8) { trailing() }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
}

@ViewBuilder private func petStatusPill(_ activeVisit: Visit?) -> some View {
    if let v = activeVisit {
        HStack(spacing: 8) {
            Image(systemName: "clock")
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let secs = max(0, Int(Date().timeIntervalSince(v.startedAt)))
                Text(hms(secs)).monospacedDigit()
            }
        }
        .font(.callout.weight(.bold))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
        .foregroundStyle(.blue)
    } else {
        Text(NSLocalizedString("client_detail.available", comment: ""))
            .font(.caption.weight(.bold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

/// Adaptive pet actions keep the outlined History label readable in both appearances.
@ViewBuilder private func actionButton(title: String, systemImage: String, tint: Color = .blue, borderOnly: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.callout)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(borderOnly ? Color.primary : Color.white)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 58)
        .padding(.vertical, 8)
        .background(borderOnly ? DS.ColorToken.surface : tint, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderOnly ? Color.primary.opacity(0.25) : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .pressScaleStyle()
    .accessibilityLabel(title)
}

private extension Logger {
    static let clientDetailView = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "ClientDetailView")
}

// Nonisolated small helper for duration string to use inside TimelineView

// Format as H:MM:SS with monospaced digits for stable layout
private func hms(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    return String(format: "%d:%02d:%02d", h, m, s)
}
