//
//  NewClientSheet.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//

import SwiftUI
import SwiftData
import Observation
import PhotosUI
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
struct NewClientSheet: View {
    private enum FocusField: Hashable {
        case firstName
        case lastName
        case phone
        case email
        case address
        case contactName(UUID)
        case contactPhone(UUID)
        case petName(UUID)
        case petBreed(UUID)
        case petColor(UUID)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    private let modelContext: ModelContext
    @State private var viewModel: NewClientViewModel?
    @State private var didFocusInitialField = false
    @State private var createButtonFrame: CGRect?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var toolbarWalkthroughFrames: [WalkthroughAnchorID: CGRect] {
        #if os(iOS)
        if horizontalSizeClass == .compact, let createButtonFrame {
            return [.ncSave: createButtonFrame]
        }
        #endif
        return [:]
    }
    @FocusState private var focusedField: FocusField?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var body: some View {
        sheetContent
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 640, minHeight: 560, idealHeight: 680)
        #endif
        .onAppear {
            if viewModel == nil {
                viewModel = NewClientViewModel(modelContext: modelContext)
            }
            focusInitialFieldIfNeeded()
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if let walkthrough {
            navigationContent
                .walkthroughOverlay(walkthrough, presenting: .newClient, externalFrames: toolbarWalkthroughFrames)
        } else {
            navigationContent
        }
    }

    private var navigationContent: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    formContent(viewModel)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        #if os(iOS)
        .background {
            NewClientToolbarFrameReader { createButtonFrame = $0 }
                .accessibilityHidden(true)
        }
        #endif
    }

    @ViewBuilder
    private func formContent(_ viewModel: NewClientViewModel) -> some View {
        @Bindable var viewModel = viewModel
        let form = ScrollView {
            VStack(spacing: 16) {
                // Owner Info Card
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("new_client.owner", comment: "")).font(.subheadline.weight(.semibold))
                        inputField(
                            NSLocalizedString("new_client.first_name", comment: ""),
                            text: $viewModel.first,
                            accessibilityIdentifier: "newClient.firstName",
                            validationError: viewModel.validationError(for: .first),
                            focus: .firstName,
                            nextFocus: .lastName
                        )
                        .onChange(of: viewModel.first) { _, newValue in
                            viewModel.clearValidationError(for: .first)
                            // The Academy's "Add a client" stop waits for a name.
                            if walkthrough?.currentStep?.id == WalkthroughStepID.newClientOwner,
                               !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                walkthrough?.releaseActionRequirement(reason: "a first name was typed")
                            }
                        }

                        inputField(
                            NSLocalizedString("new_client.last_name", comment: ""),
                            text: $viewModel.last,
                            accessibilityIdentifier: "newClient.lastName",
                            validationError: viewModel.validationError(for: .last),
                            focus: .lastName,
                            nextFocus: .phone
                        )
                        .onChange(of: viewModel.last) { _, _ in viewModel.clearValidationError(for: .last) }

                        inputField(
                            NSLocalizedString("new_client.phone", comment: ""),
                            text: $viewModel.phone,
                            accessibilityIdentifier: "newClient.phone",
                            validationError: viewModel.validationError(for: .phone),
                            focus: .phone,
                            nextFocus: .email,
                            maxLength: TextInputLimits.phone
                        )
                            .phoneFieldFormatting($viewModel.phone)
                            .onChange(of: viewModel.phone) { _, _ in viewModel.clearValidationError(for: .phone) }

                        inputField(
                            NSLocalizedString("new_client.email", comment: ""),
                            text: $viewModel.email,
                            accessibilityIdentifier: "newClient.email",
                            validationError: viewModel.validationError(for: .email),
                            focus: .email,
                            nextFocus: .address,
                            maxLength: TextInputLimits.email
                        )
                        .onChange(of: viewModel.email) { _, _ in viewModel.clearValidationError(for: .email) }

                        inputField(
                            NSLocalizedString("new_client.address", comment: ""),
                            text: $viewModel.address,
                            accessibilityIdentifier: "newClient.address",
                            focus: .address,
                            nextFocus: firstPetFocus(in: viewModel),
                            maxLength: TextInputLimits.address
                        )
                    }
                }
                .walkthroughTarget(.ncOwner)
                .padding(.horizontal)

                // Emergency Contacts Card
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(NSLocalizedString("new_client.emergency_contacts", comment: "")).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                viewModel.addContact()
                                HapticManager.selectionChanged()
                            } label: {
                                Label(NSLocalizedString("new_client.add", comment: ""), systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(DS.ColorToken.primary)
                            .accessibilityLabel(
                                AppLocalization.localized(
                                    "client_detail.add_emergency_contact",
                                    value: "Add emergency contact"
                                )
                            )
                            .accessibilityIdentifier("newClient.addContact")
                        }
                        if viewModel.contacts.isEmpty {
                            Text(NSLocalizedString("new_client.add_contact_hint", comment: ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach($viewModel.contacts) { $contact in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Spacer()
                                        Button(role: .destructive) {
                                            viewModel.removeContact(id: contact.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .tint(.red)
                                        .accessibilityLabel(AppLocalization.localized("common.delete", value: "Delete"))
                                    }
                                    inputField(
                                        NSLocalizedString("new_client.contact_name", comment: ""),
                                        text: $contact.name,
                                        accessibilityIdentifier: "newClient.contactName",
                                        validationError: viewModel.contactValidationError(for: contact.id, field: .name),
                                        focus: .contactName(contact.id),
                                        nextFocus: .contactPhone(contact.id)
                                    )
                                    .onChange(of: contact.name) { _, _ in viewModel.clearContactValidationErrors(for: contact.id) }
                                    inputField(
                                        NSLocalizedString("new_client.contact_phone", comment: ""),
                                        text: $contact.phone,
                                        accessibilityIdentifier: "newClient.contactPhone",
                                        validationError: viewModel.contactValidationError(for: contact.id, field: .phone),
                                        focus: .contactPhone(contact.id),
                                        nextFocus: firstPetFocus(in: viewModel),
                                        maxLength: TextInputLimits.phone
                                    )
                                        .phoneFieldFormatting($contact.phone)
                                        .onChange(of: contact.phone) { _, _ in viewModel.clearContactValidationErrors(for: contact.id) }
                                }
                                .padding()
                                .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.horizontal)

                // Pet Management Card
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(NSLocalizedString("new_client.pets", comment: "")).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                viewModel.addPet()
                                HapticManager.selectionChanged()
                            } label: {
                                Label(NSLocalizedString("new_client.add_pet", comment: ""), systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(DS.ColorToken.primary)
                            .accessibilityLabel(AppLocalization.localized("client_detail.add_pet", value: "Add Pet"))
                            .accessibilityIdentifier("newClient.addPet")
                        }
                        if viewModel.pets.isEmpty {
                            Text(NSLocalizedString("new_client.add_pet_hint", comment: ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach($viewModel.pets) { $pet in
                            VStack(alignment: .leading, spacing: 8) {
                                if viewModel.pets.count > 1 {
                                    HStack {
                                        Spacer()
                                        Button(role: .destructive) {
                                            viewModel.removePet(id: pet.id)
                                        } label: {
                                            Label(NSLocalizedString("new_client.remove_pet", comment: ""), systemImage: "trash")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .tint(.red)
                                        .accessibilityLabel(NSLocalizedString("new_client.remove_pet", comment: ""))
                                    }
                                }
                                PetProfileForm(
                                    name: $pet.name, species: $pet.species,
                                    gender: Binding($pet.gender, replacingNilWith: .male),
                                    breed: $pet.breed, color: $pet.color, photoData: $pet.photoData,
                                    birthdate: $pet.knownBirthdate, identifierPrefix: "newClient.pet",
                                    focusName: focusedField == .petName(pet.id)
                                )
                            }
                        }
                    }
                }
                .walkthroughTarget(.ncPets)
                .padding(.horizontal)
            }
            .padding(.vertical)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }

        #if os(macOS)
        VStack(spacing: 0) {
            form
            Divider()
            macOSFooterActions(viewModel)
        }
        .navigationTitle(NSLocalizedString("new_client.new_client", comment: ""))
        .alert(
            Text(NSLocalizedString("common.error", comment: "")),
            isPresented: Binding(
                get: { viewModel.appError != nil },
                set: { if !$0 { viewModel.appError = nil } }
            ),
            presenting: viewModel.appError
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
        #else
        form
        .navigationTitle(NSLocalizedString("new_client.new_client", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { dismiss() }
                    .accessibilityIdentifier("newClient.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                createButton(viewModel)
            }
        }
        .alert(
            Text(NSLocalizedString("common.error", comment: "")),
            isPresented: Binding(
                get: { viewModel.appError != nil },
                set: { if !$0 { viewModel.appError = nil } }
            ),
            presenting: viewModel.appError
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
        #endif
    }

    private func createClient(_ viewModel: NewClientViewModel) {
        Logger.newClient.info("Create button tapped")
        Task {
            let outcome = await viewModel.createClient()
            Logger.newClient.info("Create button outcome: \(String(describing: outcome))")
            if outcome == .created {
                dismiss()
            }
        }
    }

    private func createButton(_ viewModel: NewClientViewModel) -> some View {
        Button {
            createClient(viewModel)
        } label: {
            if viewModel.isSaving {
                ProgressView()
            } else {
                Label(NSLocalizedString("common.create", comment: ""), systemImage: "checkmark.circle.fill")
            }
        }
        .disabled(viewModel.isSaving)
        .accessibilityIdentifier("newClient.create")
    }

    #if os(macOS)
    private func macOSFooterActions(_ viewModel: NewClientViewModel) -> some View {
        HStack(spacing: 10) {
            Spacer()

            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("newClient.cancel")

            createButton(viewModel)
                // A look-only tour stop (salon with real clients) intercepts
                // clicks, but not keyboard shortcuts: Return must not save.
                .keyboardShortcut(isCreateLockedByTour ? nil : KeyboardShortcut.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .walkthroughAnchor(.ncSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
    #endif

    @ViewBuilder
    private func inputField(
        _ title: String,
        text: Binding<String>,
        accessibilityIdentifier: String? = nil,
        validationError: String? = nil,
        focus: FocusField,
        nextFocus: FocusField?,
        submitLabel: SubmitLabel = .next,
        maxLength: Int = TextInputLimits.name
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text)
                .optionalAccessibilityIdentifier(accessibilityIdentifier)
                .focused($focusedField, equals: focus)
                .submitLabel(submitLabel)
                .textLengthLimit(text, to: maxLength)
                .onSubmit {
                    focusedField = nextFocus
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(validationError == nil ? DS.ColorToken.border : DS.ColorToken.danger, lineWidth: validationError == nil ? 1 : 1.5)
                )

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(DS.ColorToken.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(accessibilityIdentifier ?? "field").error")
            }
        }
    }

    /// The guided tour is showing this form on a stop that only explains.
    private var isCreateLockedByTour: Bool {
        guard let walkthrough, walkthrough.isActive,
              let step = walkthrough.currentStep, step.presents == .newClient
        else { return false }
        return !step.allowsTargetInteraction
    }

    private func focusInitialFieldIfNeeded() {
        guard !didFocusInitialField else { return }
        guard walkthrough?.currentStep?.presents != .newClient else { return }
        didFocusInitialField = true
        DispatchQueue.main.async {
            focusedField = .firstName
        }
    }

    private func firstPetFocus(in viewModel: NewClientViewModel) -> FocusField? {
        guard let pet = viewModel.pets.first else { return nil }
        return .petName(pet.id)
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private extension Logger {
    static let newClient = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "NewClient")
}

#if os(iOS)
/// A toolbar is a separate SwiftUI host, so use UIKit's window coordinates.
private struct NewClientToolbarFrameReader: UIViewRepresentable {
    var onFrameChange: (CGRect) -> Void

    /// Creates a noninteractive marker in the presentation's native view hierarchy.
    func makeUIView(context: Context) -> FrameView {
        let view = FrameView()
        view.isUserInteractionEnabled = false
        view.onFrameChange = onFrameChange
        return view
    }

    /// Refreshes the callback and resamples the current toolbar bounds.
    func updateUIView(_ uiView: FrameView, context: Context) {
        uiView.onFrameChange = onFrameChange
        uiView.reportFrame()
    }

    final class FrameView: UIView {
        var onFrameChange: ((CGRect) -> Void)?
        private var lastFrame: CGRect?
        private var retryCount = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrame()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrame()
        }

        /// Reports the native button's minimum touch bounds after the layout pass.
        func reportFrame() {
            guard let window else { return }
            guard let button = targetView(in: window), button.bounds.width > 0, button.bounds.height > 0 else {
                guard retryCount < 20 else { return }
                retryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reportFrame() }
                return
            }
            retryCount = 0
            let measured = button.convert(button.bounds, to: window)
            let frame = measured.insetBy(dx: -max(0, 44 - measured.width) / 2,
                                         dy: -max(0, 44 - measured.height) / 2)
            guard frame != lastFrame else { return }
            lastFrame = frame
            DispatchQueue.main.async { [weak self] in self?.onFrameChange?(frame) }
        }

        /// Finds only the app's identified Create control in this presentation's window.
        private func targetView(in root: UIView) -> UIView? {
            if root.accessibilityIdentifier == "newClient.create", !root.isHidden, root.alpha > 0 {
                return root
            }
            for child in root.subviews {
                if let target = targetView(in: child) { return target }
            }
            return nil
        }
    }
}
#endif
