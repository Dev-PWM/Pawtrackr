import SwiftUI

struct ChangePINSheet: View {
    @Environment(AppSettings.self) private var appSettings
    @Binding var isPresented: Bool
    @State private var currentPIN: String = ""
    @State private var newPIN: String = ""
    @State private var confirmPIN: String = ""
    @State private var errorMessage: String? = nil

    /// No PIN is stored on this device (the user finished onboarding
    /// passcode-free, or a device restore brought back `lastPINChangeDate` but
    /// not the ThisDeviceOnly Keychain PIN), so there is no current PIN to
    /// verify — this becomes a "set your PIN" flow instead of a change. Keyed on
    /// `isPINSet`, not `lastPINChangeDate`: after a restore the date survives and
    /// "Current PIN" could never validate, a dead end.
    private var isInitialSetup: Bool { !appSettings.isPINSet }

    var body: some View {
        NavigationStack {
            Form {
                Section(isInitialSetup
                        ? AppLocalization.localized("settings.pin.set", value: "Set PIN")
                        : AppLocalization.localized("settings.pin.change", value: "Change PIN")) {
                    if !isInitialSetup {
                        SecureField(AppLocalization.localized("settings.pin.current", value: "Current PIN"), text: $currentPIN)
                            .accessibilityIdentifier("settings.pin.current")
                    }
                    SecureField(AppLocalization.localized("settings.pin.new", value: "New PIN"), text: $newPIN)
                        .accessibilityIdentifier("settings.pin.new")
                    SecureField(AppLocalization.localized("settings.pin.confirm", value: "Confirm PIN"), text: $confirmPIN)
                        .accessibilityIdentifier("settings.pin.confirm")
                }
            }
            .navigationTitle(isInitialSetup
                             ? AppLocalization.localized("settings.pin.set", value: "Set PIN")
                             : AppLocalization.localized("settings.pin.change", value: "Change PIN"))
            .toolbar {
                Button(AppLocalization.localized("common.save", value: "Save")) { updatePIN() }
                    .accessibilityIdentifier("settings.pin.save")
                Button(AppLocalization.localized("common.cancel", value: "Cancel")) { isPresented = false }
                    .accessibilityIdentifier("settings.pin.cancel")
            }
            .alert(AppLocalization.localized("common.error", value: "Error"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(AppLocalization.localized("common.ok", value: "OK")) { }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func updatePIN() {
        if !isInitialSetup {
            guard appSettings.validatePIN(currentPIN) else {
                errorMessage = AppLocalization.localized("settings.pin.incorrect", value: "Incorrect PIN")
                return
            }
        }
        guard newPIN == confirmPIN else {
            errorMessage = AppLocalization.localized("settings.pin.mismatch", value: "PINs do not match")
            return
        }
        guard appSettings.changePIN(to: newPIN) else {
            errorMessage = AppLocalization.localized("settings.pin.invalid", value: "Enter a 4-digit PIN")
            return
        }
        isPresented = false
    }
}
