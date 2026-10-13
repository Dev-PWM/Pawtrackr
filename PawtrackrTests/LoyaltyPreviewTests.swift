//
//  LoyaltyPreviewTests.swift
//  PawtrackrTests
//
//  The loyalty preview card and checkout must award the same points.
//  `LoyaltyEngine.preview` is the one rule both use; these tests run the real
//  earn path (`LoyaltyCheckoutProcessor.applyEarnings`) on an in-memory store
//  and compare it with the preview for the same ticket, rules, tier and
//  rebook state.
//

import XCTest
import SwiftData
@testable import Pawtrackr

@MainActor
final class LoyaltyPreviewTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    /// When the client's previous completed visit ended, relative to `now`.
    private enum PreviousVisit: CaseIterable, CustomStringConvertible {
        case none
        case tenDaysAgo
        case exactlyAtWindow
        case justPastWindow
        case inTheFuture

        func date(relativeTo now: Date) -> Date? {
            let day: TimeInterval = 86_400
            switch self {
            case .none: return nil
            case .tenDaysAgo: return now.addingTimeInterval(-10 * day)
            case .exactlyAtWindow: return now.addingTimeInterval(-TimeInterval(LoyaltyEngine.rebookWindowDays) * day)
            case .justPastWindow: return now.addingTimeInterval(-TimeInterval(LoyaltyEngine.rebookWindowDays) * day - 60)
            case .inTheFuture: return now.addingTimeInterval(3_600)
            }
        }

        var description: String {
            switch self {
            case .none: return "no previous visit"
            case .tenDaysAgo: return "10 days ago"
            case .exactlyAtWindow: return "exactly at the window"
            case .justPastWindow: return "just past the window"
            case .inTheFuture: return "in the future"
            }
        }
    }

    private static let tickets: [Decimal] = [
        0,
        Decimal(string: "0.49")!,
        1,
        Decimal(string: "79.99")!,
        80,
        Decimal(string: "123.45")!
    ]

    private static let configs: [LoyaltyConfigSnapshot] = [
        .default,
        LoyaltyConfigSnapshot(earnMode: .pointsPerDollar, pointsPerDollar: 2, pointsPerVisit: 20, redemptionThreshold: 100, isRewardsCatalogEnabled: true),
        LoyaltyConfigSnapshot(earnMode: .pointsPerDollar, pointsPerDollar: 0, pointsPerVisit: 20, redemptionThreshold: 100, isRewardsCatalogEnabled: true),
        LoyaltyConfigSnapshot(earnMode: .flatPerVisit, pointsPerDollar: 1, pointsPerVisit: 20, redemptionThreshold: 100, isRewardsCatalogEnabled: true),
        LoyaltyConfigSnapshot(earnMode: .flatPerVisit, pointsPerDollar: 1, pointsPerVisit: 0, redemptionThreshold: 100, isRewardsCatalogEnabled: false)
    ]

    // MARK: - Parity with checkout

    func testPreviewAwardsExactlyWhatCheckoutAwards() throws {
        var checked = 0
        for config in Self.configs {
            for tier in LoyaltyTier.allCases {
                for previous in PreviousVisit.allCases {
                    for ticket in Self.tickets {
                        let awarded = try checkoutAward(ticket: ticket, config: config, tier: tier, previous: previous)
                        let rebook = LoyaltyEngine.isRebook(previousVisitEndedAt: previous.date(relativeTo: now), checkoutAt: now)
                        let preview = LoyaltyEngine.preview(ticket: ticket, config: config, tier: tier, rebook: rebook)
                        XCTAssertEqual(
                            preview.total, awarded,
                            "ticket \(ticket), \(config.earnMode) \(config.pointsPerDollar)/\(config.pointsPerVisit), \(tier), previous visit \(previous)"
                        )
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, Self.configs.count * LoyaltyTier.allCases.count * PreviousVisit.allCases.count * Self.tickets.count)
    }

    func testRebookWindowBoundaries() {
        XCTAssertFalse(LoyaltyEngine.isRebook(previousVisitEndedAt: nil, checkoutAt: now))
        XCTAssertTrue(LoyaltyEngine.isRebook(previousVisitEndedAt: PreviousVisit.tenDaysAgo.date(relativeTo: now), checkoutAt: now))
        XCTAssertTrue(LoyaltyEngine.isRebook(previousVisitEndedAt: PreviousVisit.exactlyAtWindow.date(relativeTo: now), checkoutAt: now))
        XCTAssertFalse(LoyaltyEngine.isRebook(previousVisitEndedAt: PreviousVisit.justPastWindow.date(relativeTo: now), checkoutAt: now))
        XCTAssertFalse(LoyaltyEngine.isRebook(previousVisitEndedAt: PreviousVisit.inTheFuture.date(relativeTo: now), checkoutAt: now),
                       "Clock skew must not mint a bonus.")
    }

    // MARK: - The preview itself

    func testEveryPriceTierAndReturnTimingEarnsExactlyTwenty() {
        for config in Self.configs {
            for tier in LoyaltyTier.allCases {
                for ticket in Self.tickets {
                    for rebook in [false, true] {
                        let preview = LoyaltyEngine.preview(ticket: ticket, config: config, tier: tier, rebook: rebook)
                        XCTAssertEqual(preview.basePoints, 20)
                        XCTAssertEqual(preview.tierPoints, 20)
                        XCTAssertEqual(preview.rebookBonus, 0)
                        XCTAssertEqual(preview.total, 20)
                    }
                }
            }
        }
    }

    func testResolverPicksTheOldestConfigFromRowsAsTheFetchDoes() throws {
        XCTAssertEqual(LoyaltyConfigResolver.snapshot(from: []), .default)

        let older = LoyaltyConfig()
        older.createdAt = now.addingTimeInterval(-100)
        older.setPointsPerDollar(3)
        let newer = LoyaltyConfig()
        newer.createdAt = now
        newer.setEarnMode(.flatPerVisit)
        context.insert(newer)
        context.insert(older)
        try context.save()

        XCTAssertEqual(LoyaltyConfigResolver.snapshot(from: [newer, older]), LoyaltyConfigResolver.snapshot(in: context))
        XCTAssertEqual(LoyaltyConfigResolver.snapshot(from: [newer, older]).pointsPerDollar, 3)
    }

    // MARK: - The card's rewards and wording

    func testRewardsFallBackToTheStarterCatalogOnlyWhileNoTemplateExists() throws {
        XCTAssertEqual(LoyaltyRewardCatalog.rewards(templates: [], config: .default).map(\.id), LoyaltyReward.builtInCatalog.map(\.id))

        let second = LoyaltyRewardTemplate(title: "Free Bandana", detail: "", pointCost: 40, systemImage: "gift.fill", styleRaw: "care", sortOrder: 1)
        let first = LoyaltyRewardTemplate(title: "Nail Trim", detail: "", pointCost: 60, systemImage: "gift.fill", styleRaw: "care", sortOrder: 0)
        let off = LoyaltyRewardTemplate(title: "Old Reward", detail: "", pointCost: 10, systemImage: "gift.fill", styleRaw: "care", sortOrder: 2, isEnabled: false)
        let rewards = LoyaltyRewardCatalog.rewards(templates: [second, off, first], config: .default)
        XCTAssertEqual(rewards.map(\.title), ["Nail Trim", "Free Bandana"], "The salon's enabled templates, in order.")

        XCTAssertTrue(LoyaltyRewardCatalog.rewards(templates: [off], config: .default).isEmpty,
                      "All templates switched off is not the same as none: no starter catalog.")

        let paused = LoyaltyConfigSnapshot(earnMode: .pointsPerDollar, pointsPerDollar: 1, pointsPerVisit: 20, redemptionThreshold: 100, isRewardsCatalogEnabled: false)
        XCTAssertTrue(LoyaltyRewardCatalog.rewards(templates: [first], config: paused).isEmpty)
        XCTAssertTrue(LoyaltyRewardCatalog.rewards(templates: [], config: paused).isEmpty)
    }

    func testSeededTemplatesShowTranslatedAndEditedOnesShowAsWritten() {
        defer { UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride) }
        UserDefaults.standard.set(AppLanguageOverride.es.rawValue, forKey: AppSettingsKeys.appLanguageOverride)

        let seeded = LoyaltyRewardTemplate(reward: LoyaltyReward.builtInCatalog[0], sortOrder: 0)
        XCTAssertEqual(LoyaltyRewardCatalog.displayTitle(for: seeded.displayReward), "Crédito de $10 para el salón")

        let edited = LoyaltyRewardTemplate(title: "$5 Visit Credit", detail: "", pointCost: 75, systemImage: "gift.fill", styleRaw: "credit", sortOrder: 0)
        XCTAssertEqual(LoyaltyRewardCatalog.displayTitle(for: edited.displayReward), "$5 Visit Credit", "A changed cost means the salon made it its own.")
    }

    func testExplainerMatchesFixedVisitEarningsInBothLanguages() {
        defer { UserDefaults.standard.removeObject(forKey: AppSettingsKeys.appLanguageOverride) }
        for language in [AppLanguageOverride.en, .es] {
            UserDefaults.standard.set(language.rawValue, forKey: AppSettingsKeys.appLanguageOverride)
            XCTAssertTrue(LoyaltyExplainer.earning(config: .default, currencySymbol: "$").contains("20"))
            let preview = LoyaltyEngine.preview(ticket: 999, config: .default, tier: .platinum, rebook: true)
            let lines = LoyaltyExplainer.breakdown(preview, config: .default)
            XCTAssertEqual(lines.count, 1)
            XCTAssertTrue(lines[0].contains("20"))
        }
    }

    func testMoneyIsFormattedFromDecimalWithTheSalonsSymbol() {
        XCTAssertTrue(LoyaltyExplainer.money(80, symbol: "€").contains("€"))
        XCTAssertTrue(LoyaltyExplainer.money(80, symbol: "$").contains("80"))
        XCTAssertTrue(LoyaltyExplainer.money(Decimal(string: "79.5")!, symbol: "$").contains("79"))
    }

    // MARK: - Helpers

    /// Runs the checkout earn path for a client who holds `tier` before this
    /// visit and whose previous completed visit ended as `previous` says.
    private func checkoutAward(
        ticket: Decimal,
        config: LoyaltyConfigSnapshot,
        tier: LoyaltyTier,
        previous: PreviousVisit
    ) throws -> Int {
        let client = Client(firstName: "Parity", lastName: "Check", phone: "5550100199")
        let pet = Pet(name: "Milo", species: .dog)
        pet.owner = client
        context.insert(client)
        context.insert(pet)

        // Earned the tier's threshold long ago, outside the rebook window.
        let history = Visit(pet: pet, startedAt: now.addingTimeInterval(-200 * 86_400))
        history.markCheckedOut(total: 10, now: now.addingTimeInterval(-199 * 86_400))
        history.loyaltyPointsChange = tier.threshold
        context.insert(history)

        if let previousEnd = previous.date(relativeTo: now) {
            let earlier = Visit(pet: pet, startedAt: previousEnd.addingTimeInterval(-3_600))
            earlier.markCheckedOut(total: 10, now: previousEnd)
            context.insert(earlier)
        }

        let visit = Visit(pet: pet, startedAt: now.addingTimeInterval(-3_600))
        visit.markCheckedOut(total: ticket, now: now)
        let payment = Payment(amount: ticket, method: .cash, paidAt: now)
        context.insert(payment)
        visit.attachPayment(payment)
        context.insert(visit)
        try context.save()

        XCTAssertEqual(
            LoyaltyEngine.tier(forLifetimeEarned: LoyaltyEngine.lifetimeEarnedPoints(for: client, excluding: visit.uuid)),
            tier,
            "Test setup: the client should hold \(tier) before this visit."
        )

        try LoyaltyCheckoutProcessor.applyEarnings(
            visit: visit,
            pet: pet,
            total: ticket,
            in: context,
            now: now,
            config: config
        )
        return visit.loyaltyPointsChange
    }
}
