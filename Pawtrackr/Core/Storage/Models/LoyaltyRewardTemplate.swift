//
//  LoyaltyRewardTemplate.swift
//  Pawtrackr
//
//  Owner-editable reward definitions for the premium loyalty catalog.
//

import Foundation
import SwiftData

@Model
final class LoyaltyRewardTemplate {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: UUID = DeviceIdentity.currentID

    var title: String = ""
    var detail: String = ""
    var pointCost: Int = 1
    var systemImage: String = "gift.fill"
    var styleRaw: String = LoyaltyReward.Style.credit.rawValue
    var sortOrder: Int = 0
    var isEnabled: Bool = true
    var creditAmount: Decimal? = nil

    @Transient
    var style: LoyaltyReward.Style {
        get { LoyaltyReward.Style(rawValue: styleRaw) ?? .credit }
        set {
            styleRaw = newValue.rawValue
            markModified()
        }
    }

    init(
        title: String,
        detail: String,
        pointCost: Int,
        systemImage: String,
        styleRaw: String,
        sortOrder: Int,
        isEnabled: Bool = true,
        creditAmount: Decimal? = nil
    ) {
        uuid = UUID()
        createdAt = .now
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
        self.title = TextInputLimits.clamped(title, to: TextInputLimits.name)
        self.detail = TextInputLimits.clamped(detail, to: TextInputLimits.notes)
        self.pointCost = max(1, pointCost)
        self.systemImage = Self.normalizedSystemImage(systemImage)
        self.styleRaw = LoyaltyReward.Style(rawValue: styleRaw)?.rawValue ?? LoyaltyReward.Style.credit.rawValue
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.creditAmount = creditAmount
    }

    convenience init(reward: LoyaltyReward, sortOrder: Int) {
        self.init(
            title: reward.title,
            detail: reward.detail,
            pointCost: reward.pointCost,
            systemImage: reward.systemImage,
            styleRaw: reward.style.rawValue,
            sortOrder: sortOrder,
            creditAmount: reward.checkoutCreditAmount
        )
    }

    static func seedTemplates() -> [LoyaltyRewardTemplate] {
        LoyaltyReward.builtInCatalog.enumerated().map { index, reward in
            LoyaltyRewardTemplate(reward: reward, sortOrder: index)
        }
    }

    var displayReward: LoyaltyReward {
        LoyaltyReward(
            id: uuid.uuidString,
            title: title,
            detail: detail,
            pointCost: pointCost,
            systemImage: systemImage,
            style: style,
            creditAmount: creditAmount
        )
    }

    var reward: LoyaltyReward {
        displayReward
    }

    func update(
        title: String,
        detail: String,
        pointCost: Int,
        systemImage: String,
        style: LoyaltyReward.Style,
        sortOrder: Int,
        isEnabled: Bool
    ) {
        self.title = TextInputLimits.clamped(title, to: TextInputLimits.name)
        self.detail = TextInputLimits.clamped(detail, to: TextInputLimits.notes)
        self.pointCost = max(1, pointCost)
        self.systemImage = Self.normalizedSystemImage(systemImage)
        self.styleRaw = style.rawValue
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        markModified()
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        markModified()
    }

    func markModified() {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
    }

    private static func normalizedSystemImage(_ value: String) -> String {
        let symbol = TextInputLimits.clamped(value, to: TextInputLimits.shortText)
        return symbol.isEmpty ? "gift.fill" : symbol
    }
}

extension LoyaltyRewardTemplate: Identifiable {
    var id: UUID { uuid }
}
