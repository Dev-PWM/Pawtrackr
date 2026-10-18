//
//  View+EmailField.swift
//  Pawtrackr
//
//  Centralizes keyboard and autofill behavior for email inputs.
//

import SwiftUI

extension View {
    /// Configures a text field for email entry.
    ///
    /// On iPhone and iPad this shows the email keyboard (with `@` and `.` on the
    /// first layer), offers email autofill, and stops auto-capitalization and
    /// autocorrect from changing the address. On macOS only the content type applies.
    func emailFieldInput() -> some View {
        modifier(EmailFieldInput())
    }
}

private struct EmailFieldInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            #endif
    }
}
