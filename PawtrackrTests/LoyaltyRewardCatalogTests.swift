import XCTest
@testable import Pawtrackr

final class LoyaltyRewardCatalogTests: XCTestCase {
    func testBuiltInCatalogOrdersRewardsByPointCost() {
        let costs = LoyaltyReward.builtInCatalog.map(\.pointCost)

        XCTAssertEqual(costs, [100, 200, 500])
        XCTAssertEqual(LoyaltyReward.builtInCatalog.map(\.title), ["$10 Salon Credit", "$20 Salon Credit", "VIP Spa Package"])
    }

    func testCreditNeedsEnoughVisitValueToUseItsFullAmount() {
        let credit = LoyaltyReward.builtInCatalog[1]
        XCTAssertFalse(credit.isApplicable(to: 19))
        XCTAssertTrue(credit.isApplicable(to: 20))
        XCTAssertTrue(LoyaltyReward.builtInCatalog[2].isApplicable(to: 0))
    }

    func testRewardEligibilityRequiresEnoughPoints() throws {
        let reward = try XCTUnwrap(LoyaltyReward.builtInCatalog.first)

        XCTAssertFalse(reward.isRedeemable(with: reward.pointCost - 1))
        XCTAssertTrue(reward.isRedeemable(with: reward.pointCost))
    }

    func testTemplateDisplayRewardKeepsRedeemabilityRules() {
        let template = LoyaltyRewardTemplate(
            title: "$10 Credit",
            detail: "Apply at checkout.",
            pointCost: 100,
            systemImage: "ticket.fill",
            styleRaw: LoyaltyReward.Style.credit.rawValue,
            sortOrder: 0
        )

        let reward = template.displayReward

        XCTAssertFalse(reward.isRedeemable(with: 99))
        XCTAssertTrue(reward.isRedeemable(with: 100))
    }
}
