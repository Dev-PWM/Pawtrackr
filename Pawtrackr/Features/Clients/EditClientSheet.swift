//
//  EditClientSheet.swift
//  Pawtrackr
//
//  Allows editing owner/contact info for an existing client.
//

import SwiftUI
import SwiftData

struct EditClientSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx

    let client: Client

    // Editable fields
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var phone: String = ""
    @State private var email: String = ""
    @State private var address: String = ""

    // Alerts
    @State private var appError: AppError? = nil
    @State private var attemptedSubmit = false
    /// What the form opened with, for the changed-on-another-device check.
    @State private var baseline: ClientEditBaseline? = nil
    @State private var showsConflictAlert = false

    init(client: Client) {
        self.client = client
        // State is initialized in .onAppear to ensure latest values
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("new_client.owner_section", comment: "")) {
                    TextField(NSLocalizedString("new_client.first_name", comment: ""), text: $firstName)
                        .accessibilityIdentifier("editClient.firstName")
                        .textLengthLimit($firstName, to: TextInputLimits.name)
                    #if os(iOS)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    #endif
                    TextField(NSLocalizedString("new_client.last_name", comment: ""), text: $lastName)
                        .accessibilityIdentifier("editClient.lastName")
                        .textLengthLimit($lastName, to: TextInputLimits.name)
                    #if os(iOS)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
                    #endif
                    TextField(NSLocalizedString("new_client.phone", comment: ""), text: $phone)
                        .accessibilityIdentifier("editClient.phone")
                        .phoneFieldFormatting($phone)
                        .textLengthLimit($phone, to: TextInputLimits.phone)
                    TextField(NSLocalizedString("new_client.email", comment: ""), text: $email)
                        .accessibilityIdentifier("editClient.email")
                        .textLengthLimit($email, to: TextInputLimits.email)
                        .emailFieldInput()
                    TextField(NSLocalizedString("new_client.address", comment: ""), text: $address)
                        .accessibilityIdentifier("editClient.address")
                        .textLengthLimit($address, to: TextInputLimits.address)
                    #if os(iOS)
                    .textContentType(.fullStreetAddress)
                    #endif
                }

                // Notes intentionally omitted from client edit per requirements.
            }
            .navigationTitle(NSLocalizedString("client_details.edit", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { dismiss() }
                        .accessibilityIdentifier("editClient.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "")) {
                        attemptedSubmit = true
                        save()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier("editClient.save")
                }
            }
            .alert(item: $appError) { error in
                Alert(
                    title: Text(NSLocalizedString("common.error", comment: "")),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "")))
                )
            }
            .onAppear(perform: loadFromClient)
        }
        // Kept off the Form, which already hosts the error alert: two alerts
        // on one view can stop the second from presenting.
        .alert(
            AppLocalization.localized("client_edit.conflict.title", value: "Changed on Another Device"),
            isPresented: $showsConflictAlert
        ) {
            Button(AppLocalization.localized("client_edit.conflict.save_mine", value: "Save My Changes")) {
                save(overwrite: true)
            }
            Button(AppLocalization.localized("client_edit.conflict.discard_mine", value: "Discard My Changes"), role: .destructive) {
                dismiss()
            }
        } message: {
            Text(String(
                format: AppLocalization.localized(
                    "client_edit.conflict.message_fmt",
                    value: "%@ was changed on another device while you were editing. Save My Changes keeps any fields you didn't edit as the other device left them."
                ),
                conflictName
            ))
        }
    }

    private var conflictName: String {
        let name = [baseline?.fields.firstName ?? client.firstName, baseline?.fields.lastName ?? client.lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? AppLocalization.localized("client_edit.conflict.this_client", value: "This client") : name
    }

    private func loadFromClient() {
        // Once per presentation: onAppear can run again, and re-capturing the
        // baseline then would hide a change made elsewhere in between.
        guard baseline == nil else { return }
        ClientEditSaver.refresh(client)
        let opened = ClientEditBaseline(client)
        baseline = opened
        firstName = opened.fields.firstName
        lastName = opened.fields.lastName
        phone = ClientContactFields.formPhoneText(opened.fields.phone)
        email = opened.fields.email ?? ""
        address = opened.fields.address ?? ""
        // Notes not editable here.
    }

    private var form: ClientEditForm {
        ClientEditForm(firstName: firstName, lastName: lastName, phone: phone, email: email, address: address)
    }

    private var isValid: Bool {
        !firstName.trimmed.isEmpty &&
        !lastName.trimmed.isEmpty &&
        form.proposedFields(original: (baseline ?? ClientEditBaseline(client)).fields) != nil &&
        (email.trimmed.isEmpty || isValidEmail(email))
    }

    private func save(overwrite: Bool = false) {
        guard let baseline else { return }
        if !email.trimmed.isEmpty && !isValidEmail(email) {
            appError = .validation(.custom(message: NSLocalizedString("new_client.error.email_invalid_long", comment: "")))
            return
        }

        let outcome = ClientEditSaver.save(
            form,
            baseline: baseline,
            container: ctx.container,
            refreshing: client.modelContext ?? ctx,
            overwrite: overwrite
        )
        switch outcome {
        case .saved, .unchanged:
            dismiss()
        case .changedElsewhere:
            showsConflictAlert = true
        case .invalidPhone:
            appError = .validation(.invalidPhoneNumber)
        case .missing:
            appError = .database(AppLocalization.localized(
                "client_edit.missing",
                value: "This client is no longer on this device, so your changes weren't saved."
            ))
        case .failed(let message):
            appError = .database(String(format: NSLocalizedString("common.save_failed", comment: ""), message))
        }
    }

    private func isValidEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}
