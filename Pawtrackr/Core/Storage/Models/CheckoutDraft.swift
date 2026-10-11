//
//  CheckoutDraft.swift
//  Pawtrackr
//

import Foundation

struct CheckoutDraft: Codable, Equatable, Sendable {
    var visitID: UUID
    var petID: UUID
    var updatedAt: Date
    var currentStepRawValue: Int
    var sessionNotes: String
    var amountString: String
    var tipAmountString: String
    var selectedTipPercentage: Int?
    var selectedServiceUUIDs: [UUID]
    var selectedAddOnUUIDs: [UUID]
    var selectedPaymentMethodRawValue: String
    var beforePhotoData: Data?
    var afterPhotoData: Data?
    var hadBeforePhoto: Bool
    var hadAfterPhoto: Bool
    var externalReference: String
    var tags: [String]
    var selectedLoyaltyReward: LoyaltyReward?

    private enum CodingKeys: String, CodingKey {
        case visitID
        case petID
        case updatedAt
        case currentStepRawValue
        case sessionNotes
        case amountString
        case tipAmountString
        case selectedTipPercentage
        case selectedServiceUUIDs
        case selectedAddOnUUIDs
        case selectedPaymentMethodRawValue
        case beforePhotoData
        case afterPhotoData
        case hadBeforePhoto
        case hadAfterPhoto
        case externalReference
        case tags
        case selectedLoyaltyReward
    }

    init(
        visitID: UUID,
        petID: UUID,
        updatedAt: Date = .now,
        currentStepRawValue: Int,
        sessionNotes: String,
        amountString: String,
        tipAmountString: String = "",
        selectedTipPercentage: Int? = nil,
        selectedServiceUUIDs: [UUID],
        selectedAddOnUUIDs: [UUID],
        selectedPaymentMethodRawValue: String,
        beforePhotoData: Data?,
        afterPhotoData: Data?,
        hadBeforePhoto: Bool = false,
        hadAfterPhoto: Bool = false,
        externalReference: String,
        tags: [String],
        selectedLoyaltyReward: LoyaltyReward? = nil
    ) {
        self.visitID = visitID
        self.petID = petID
        self.updatedAt = updatedAt
        self.currentStepRawValue = currentStepRawValue
        self.sessionNotes = sessionNotes
        self.amountString = amountString
        self.tipAmountString = tipAmountString
        self.selectedTipPercentage = selectedTipPercentage
        self.selectedServiceUUIDs = selectedServiceUUIDs
        self.selectedAddOnUUIDs = selectedAddOnUUIDs
        self.selectedPaymentMethodRawValue = selectedPaymentMethodRawValue
        self.beforePhotoData = beforePhotoData
        self.afterPhotoData = afterPhotoData
        self.hadBeforePhoto = hadBeforePhoto
        self.hadAfterPhoto = hadAfterPhoto
        self.externalReference = externalReference
        self.tags = tags
        self.selectedLoyaltyReward = selectedLoyaltyReward
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visitID = try container.decode(UUID.self, forKey: .visitID)
        petID = try container.decode(UUID.self, forKey: .petID)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        currentStepRawValue = try container.decode(Int.self, forKey: .currentStepRawValue)
        sessionNotes = try container.decode(String.self, forKey: .sessionNotes)
        amountString = try container.decode(String.self, forKey: .amountString)
        tipAmountString = try container.decodeIfPresent(String.self, forKey: .tipAmountString) ?? ""
        selectedTipPercentage = try container.decodeIfPresent(Int.self, forKey: .selectedTipPercentage)
        selectedServiceUUIDs = try container.decode([UUID].self, forKey: .selectedServiceUUIDs)
        selectedAddOnUUIDs = try container.decode([UUID].self, forKey: .selectedAddOnUUIDs)
        selectedPaymentMethodRawValue = try container.decode(String.self, forKey: .selectedPaymentMethodRawValue)
        beforePhotoData = try container.decodeIfPresent(Data.self, forKey: .beforePhotoData)
        afterPhotoData = try container.decodeIfPresent(Data.self, forKey: .afterPhotoData)
        hadBeforePhoto = try container.decodeIfPresent(Bool.self, forKey: .hadBeforePhoto) ?? (beforePhotoData != nil)
        hadAfterPhoto = try container.decodeIfPresent(Bool.self, forKey: .hadAfterPhoto) ?? (afterPhotoData != nil)
        externalReference = try container.decode(String.self, forKey: .externalReference)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        selectedLoyaltyReward = try container.decodeIfPresent(LoyaltyReward.self, forKey: .selectedLoyaltyReward)
    }
}
