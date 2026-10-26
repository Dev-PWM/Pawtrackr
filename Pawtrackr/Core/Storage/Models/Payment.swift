//
//  Payment.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//  Updated by Assistant on 2025-09-03.
//

import Foundation
import SwiftData

@Model
final class Payment {
    // MARK: - Properties

    /// The payment amount (always non-negative and rounded to 2 decimal places).
    var amount: Decimal = Decimal.zero

    /// Persisted payment method, stored as the enum's String rawValue. Storing a
    /// `Codable` enum directly makes SwiftData persist it as a "composite
    /// attribute" that fatally and uncatchably aborts any `[Payment]` fetch if a
    /// record holds an undecodable value. Mirrors `CheckoutTransaction.methodRaw`.
    var methodRaw: String = Payment.Method.cash.rawValue

    /// Non-persisted view over `methodRaw`, preserving the existing
    /// `payment.method` API. `@Transient` is REQUIRED — without it the `@Model`
    /// macro still synthesizes the crashing composite attribute.
    @Transient
    var method: Method {
        get { Method(rawValue: methodRaw) ?? .cash }
        set { methodRaw = newValue.rawValue }
    }
    var paidAt: Date = Date()
    var updatedAt: Date = Date()
    var note: String?
    var externalReference: String?
    var lastModifiedBy: UUID = DeviceIdentity.currentID
    var lastModifiedAt: Date = Date()

    // MARK: - Relationships
    var visit: Visit?

    // MARK: - Init

    init(amount: Decimal,
         method: Method,
         paidAt: Date = .now,
         note: String? = nil,
         externalReference: String? = nil) {
        self.amount = max(0, amount).roundedMoney()
        self.methodRaw = method.rawValue
        self.paidAt = paidAt
        self.updatedAt = .now
        self.note = note
        self.externalReference = externalReference
        self.lastModifiedBy = DeviceIdentity.currentID
        self.lastModifiedAt = .now
    }

    // MARK: - Mutating API
    func setAmount(_ newAmount: Decimal) {
        amount = max(0, newAmount).roundedMoney()
        didUpdate()
    }


    func markModified() {
        lastModifiedBy = DeviceIdentity.currentID
        lastModifiedAt = .now
        updatedAt = .now
    }

    private func didUpdate() {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
        lastModifiedAt = .now
    }
    
}

// MARK: - Payment Method Enum

extension Payment {
    enum Method: String, Codable, CaseIterable, Identifiable {
        case cash, debitCard, creditCard, zelle, other

        enum ReferenceFormat: Equatable {
            case none
            case cardLast4
            case transactionID
            case freeform
        }

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .cash:
                return AppLocalization.localized("payment.method.cash", value: "Cash")
            case .debitCard:
                return AppLocalization.localized("payment.method.debit_card", value: "Debit")
            case .creditCard:
                return AppLocalization.localized("payment.method.credit_card", value: "Credit")
            case .zelle:
                return AppLocalization.localized("payment.method.zelle", value: "Zelle")
            case .other:
                return AppLocalization.localized("payment.method.other", value: "Other")
            }
        }

        var systemImage: String {
            switch self {
            case .cash: return "banknote"
            case .debitCard, .creditCard: return "creditcard"
            case .zelle: return "dollarsign.circle"
            case .other: return "questionmark.circle"
            }
        }

        var requiresExternalReference: Bool {
            switch self {
            case .debitCard, .creditCard, .zelle: return true
            case .cash, .other: return false
            }
        }

        var referenceFormat: ReferenceFormat {
            switch self {
            case .cash: return .none
            case .debitCard, .creditCard: return .cardLast4
            case .zelle: return .transactionID
            case .other: return .freeform
            }
        }

        var referenceFieldTitle: String {
            switch self {
            case .cash, .other:
                return AppLocalization.localized("payment.reference.title", value: "Reference")
            case .debitCard, .creditCard:
                return AppLocalization.localized("payment.reference.last4", value: "Last 4 Digits")
            case .zelle:
                return AppLocalization.localized("payment.reference.transaction_id", value: "Transaction ID")
            }
        }

        var referencePlaceholder: String {
            switch self {
            case .cash:
                return AppLocalization.localized("payment.reference.placeholder_optional_note", value: "Optional note")
            case .debitCard, .creditCard:
                return AppLocalization.localized("payment.reference.placeholder_last4", value: "1234")
            case .zelle:
                return AppLocalization.localized("payment.reference.placeholder_transaction_id", value: "ZELLE-48291")
            case .other:
                return AppLocalization.localized("payment.reference.placeholder_reference", value: "Reference")
            }
        }

        var referenceHelperText: String {
            switch self {
            case .cash:
                return AppLocalization.localized("payment.reference.helper_cash", value: "You can leave this blank for cash payments.")
            case .debitCard, .creditCard:
                return AppLocalization.localized("payment.reference.helper_card", value: "Use the last 4 digits from the card or terminal slip.")
            case .zelle:
                return AppLocalization.localized("payment.reference.helper_zelle", value: "Use the confirmation or transfer ID from the payment.")
            case .other:
                return AppLocalization.localized("payment.reference.helper_other", value: "Add any note that will help you reconcile the payment later.")
            }
        }

        func normalizeReference(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

            switch referenceFormat {
            case .none, .freeform:
                return trimmed
            case .cardLast4:
                let digits = trimmed.filter(\.isNumber)
                return String(digits.suffix(4))
            case .transactionID:
                return trimmed.uppercased()
            }
        }

        func isValidReference(_ value: String) -> Bool {
            let normalized = normalizeReference(value)

            switch referenceFormat {
            case .none, .freeform:
                return true
            case .cardLast4:
                return normalized.count == 4
            case .transactionID:
                return !normalized.isEmpty
            }
        }

        func validationMessage(for value: String) -> String? {
            guard requiresExternalReference else { return nil }

            let normalized = normalizeReference(value)
            guard !normalized.isEmpty else {
                return String(format: AppLocalization.localized("payment.reference.validation.required_fmt", value: "Enter %@ to continue."), referenceFieldTitle.lowercased())
            }

            switch referenceFormat {
            case .cardLast4 where normalized.count < 4:
                return AppLocalization.localized("payment.reference.validation.last4", value: "Enter all 4 digits before continuing.")
            default:
                return nil
            }
        }

        func preservesReference(whenSwitchingFrom previousMethod: Method) -> Bool {
            referenceFormat == previousMethod.referenceFormat && referenceFormat != .none
        }
    } 
}
