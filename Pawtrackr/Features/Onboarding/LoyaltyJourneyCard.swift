import SwiftUI

/// A read-only explanation of visit-earned rewards. Animation never writes points.
struct LoyaltyJourneyCard: View {
    var tourAnchor: WalkthroughAnchorID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completedSteps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(AppLocalization.localized("loyalty.journey.title", value: "Every visit has its rewards"), systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 20) {
                journeyRow(1, symbol: "pawprint", title: AppLocalization.localized("loyalty.journey.checkin", value: "Check in"), detail: AppLocalization.localized("loyalty.journey.checkin_detail", value: "Start the pet’s visit as usual."))
                journeyRow(2, symbol: "checkmark", title: AppLocalization.localized("loyalty.journey.complete", value: "Complete the visit & record payment"), detail: AppLocalization.localized("loyalty.journey.complete_detail", value: "Points wait until the visit is checked out and paid."))
                journeyRow(3, symbol: "sparkles", title: AppLocalization.localized("loyalty.journey.saved", value: "Points, taken care of"), detail: AppLocalization.localized("loyalty.journey.saved_detail", value: "Added once to the client’s balance and saved with the visit. Nothing to enter."))
            }
            Text(AppLocalization.localized("loyalty.journey.choice_note", value: "At final checkout, choose a reward or keep the points for another visit. Credits lower the total automatically. Saved points never expire."))
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 24))
        .hairlineBorder(DS.ColorToken.border, cornerRadius: 24)
        .optionalWalkthroughTarget(tourAnchor)
        .accessibilityIdentifier("loyaltyJourney.card")
        .task {
            guard completedSteps == 0 else { return }
            guard MotionGovernor.shouldAnimate(reduceMotion: reduceMotion) else {
                completedSteps = 3
                return
            }
            for step in 1...3 {
                do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
                withAnimation(MotionSystem.snappy) { completedSteps = step }
            }
        }
    }

    /// One accessible step in the automatic visit lifecycle.
    private func journeyRow(_ step: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: completedSteps >= step ? symbol : "circle")
                .font(.body.weight(.medium))
                .foregroundStyle(completedSteps >= step ? DS.ColorToken.primary : .secondary)
                .frame(width: 38, height: 38)
                .background(DS.ColorToken.primary.opacity(completedSteps >= step ? 0.10 : 0.04), in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shared catalog selection and translated names for all loyalty surfaces.
enum LoyaltyRewardCatalog {
    /// The rewards a client can pick, as the Rewards Catalog lists them: the
    /// salon's enabled templates in their order, the built-in starter catalog
    /// while no template exists yet (what `ensureLoyaltyDefaults` seeds), and
    /// nothing while the catalog is turned off.
    static func rewards(templates: [LoyaltyRewardTemplate], config: LoyaltyConfigSnapshot) -> [LoyaltyReward] {
        guard config.isRewardsCatalogEnabled else { return [] }
        guard !templates.isEmpty else { return LoyaltyReward.builtInCatalog }
        return templates
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.displayReward)
    }

    /// The starter catalog, in order, with each reward's point cost.
    static var rewardLadder: [(points: Int, title: String)] {
        LoyaltyReward.builtInCatalog.map { ($0.pointCost, displayTitle(for: $0)) }
    }

    /// A reward's name for display. The built-in rewards, and templates still
    /// carrying a built-in reward's exact title and cost (seeded, not edited),
    /// show translated. Anything the salon wrote shows as written.
    static func displayTitle(for reward: LoyaltyReward) -> String {
        let builtIn = LoyaltyReward.builtInCatalog.first { $0.id == reward.id }
            ?? LoyaltyReward.builtInCatalog.first { $0.title == reward.title && $0.pointCost == reward.pointCost }
        guard let builtIn else { return reward.title }
        return localizedTitle(for: builtIn)
    }

    /// Literal keys, so LocalizationTests can see them.
    static func localizedTitle(for reward: LoyaltyReward) -> String {
        switch reward.id {
        case "visit-credit-5":
            return AppLocalization.localized("onboarding.loyalty_sim.reward.visit_credit_5", value: reward.title)
        case "visit-credit-10":
            return AppLocalization.localized("onboarding.loyalty_sim.reward.visit_credit_10", value: reward.title)
        case "addon-discount-15":
            return AppLocalization.localized("onboarding.loyalty_sim.reward.addon_discount_15", value: reward.title)
        case "groom-credit-20":
            return AppLocalization.localized("onboarding.loyalty_sim.reward.groom_credit_20", value: reward.title)
        case "basic-groom-credit":
            return AppLocalization.localized("onboarding.loyalty_sim.reward.basic_groom_credit", value: reward.title)
        default:
            return reward.title
        }
    }
}

enum LoyaltyExplainer {
    /// How a checkout earns, for the current rules.
    static func earning(config: LoyaltyConfigSnapshot, currencySymbol: String) -> String {
        switch config.earnMode {
        case .pointsPerDollar:
            guard config.pointsPerDollar > .zero else {
                return String(
                    format: AppLocalization.localized(
                        "loyalty.preview.earn_rate_off_fmt",
                        value: "Checkouts earn no points right now: the rule is 0 points per %@."
                    ),
                    money(1, symbol: currencySymbol)
                )
            }
            return String(
                format: AppLocalization.localized(
                    "loyalty.preview.earn_rate_fmt",
                    value: "Each checkout earns %1$@ for every %2$@ the client pays. Points are rounded down to a whole number."
                ),
                rate(config.pointsPerDollar),
                money(1, symbol: currencySymbol)
            )
        case .flatPerVisit:
            guard config.pointsPerVisit > 0 else {
                return AppLocalization.localized(
                    "loyalty.preview.earn_flat_off",
                    value: "Checkouts earn no points right now: the rule is 0 points per visit."
                )
            }
            return String(
                format: AppLocalization.localized(
                    "loyalty.preview.earn_flat_fmt",
                    value: "Each checkout earns %@, whatever the total."
                ),
                LoyaltyCopy.points(config.pointsPerVisit)
            )
        }
    }

    /// The tier ladder: thresholds and what a tier does.
    static var tiers: String {
        String(
            format: AppLocalization.localized(
                "loyalty.preview.tiers_fmt",
                value: "Points earned at checkout move a client up: Silver at %1$@, Gold at %2$@ and Platinum at %3$@. Each tier multiplies the points of every visit. Spending points never lowers a tier."
            ),
            count(LoyaltyTier.silver.threshold),
            count(LoyaltyTier.gold.threshold),
            count(LoyaltyTier.platinum.threshold)
        )
    }

    /// The rebook bonus.
    static var rebook: String {
        String(
            format: AppLocalization.localized(
                "loyalty.preview.rebook_fmt",
                value: "A visit that earns points gets %1$@ more when the client's last visit ended %2$d days ago or less."
            ),
            LoyaltyCopy.points(LoyaltyEngine.rebookBonusPoints),
            LoyaltyEngine.rebookWindowDays
        )
    }

    /// How points are spent. Redeeming only lowers the balance: the reward
    /// itself is given by the groomer.
    static func redeeming(config: LoyaltyConfigSnapshot) -> String {
        guard config.isRewardsCatalogEnabled else {
            return AppLocalization.localized(
                "loyalty.preview.redeem_paused",
                value: "Rewards are paused, so points can't be redeemed right now. Clients keep their balance."
            )
        }
        return AppLocalization.localized(
            "loyalty.preview.redeem",
            value: "To redeem, open Loyalty & Rewards on the client's profile and pick a reward. Its points come off the balance. Then give the reward yourself, for example as a discount at checkout."
        )
    }

    static var rebookToggle: String {
        String(
            format: AppLocalization.localized("loyalty.preview.rebook_toggle_fmt", value: "Back within %d days"),
            LoyaltyEngine.rebookWindowDays
        )
    }

    /// "Silver ×1.1" for the tier picker.
    static func tierChoice(_ tier: LoyaltyTier) -> String {
        String(
            format: AppLocalization.localized("loyalty.preview.tier_choice_fmt", value: "%1$@ %2$@"),
            tier.displayName,
            tier.earnRateText
        )
    }

    /// The lines under the total, e.g. "From the total: 80 points",
    /// "Silver ×1.1: 88 points", "Rebook bonus: +20 points".
    static func breakdown(_ preview: LoyaltyEarnPreview, config: LoyaltyConfigSnapshot) -> [String] {
        var lines: [String] = []
        switch config.earnMode {
        case .pointsPerDollar:
            lines.append(String(
                format: AppLocalization.localized("loyalty.preview.base_total_fmt", value: "From the total: %@"),
                LoyaltyCopy.points(preview.basePoints)
            ))
        case .flatPerVisit:
            lines.append(String(
                format: AppLocalization.localized("loyalty.preview.base_flat_fmt", value: "Per visit: %@"),
                LoyaltyCopy.points(preview.basePoints)
            ))
        }
        if preview.tier != .bronze, preview.basePoints > 0 {
            lines.append(String(
                format: AppLocalization.localized("loyalty.preview.tier_line_fmt", value: "%1$@: %2$@"),
                tierChoice(preview.tier),
                LoyaltyCopy.points(preview.tierPoints)
            ))
        }
        if preview.rebookBonus > 0 {
            lines.append(String(
                format: AppLocalization.localized("loyalty.preview.rebook_line_fmt", value: "Rebook bonus: +%@"),
                LoyaltyCopy.points(preview.rebookBonus)
            ))
        }
        return lines
    }

    /// Where the rules shown come from.
    static func rulesSource(hasSavedRules: Bool) -> String {
        hasSavedRules
            ? AppLocalization.localized(
                "loyalty.preview.rules_saved",
                value: "These are your salon's current rules. Checkout awards points with this same math."
            )
            : AppLocalization.localized(
                "loyalty.preview.rules_default",
                value: "These are the default rules. Checkout awards points with this same math, and you can change the rules in Settings > Loyalty."
            )
    }

    /// Money in the salon's currency symbol, without Double math.
    static func money(_ amount: Decimal, symbol: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        formatter.currencySymbol = symbol
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(symbol)\(amount)"
    }

    /// "1 point", "2 points", or "1.5 points" for a fractional rate.
    static func rate(_ pointsPerUnit: Decimal) -> String {
        var value = pointsPerUnit
        var whole = Decimal()
        NSDecimalRound(&whole, &value, 0, .down)
        if whole == pointsPerUnit {
            return LoyaltyCopy.points((whole as NSDecimalNumber).intValue)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLocalization.currentLocale
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: pointsPerUnit as NSDecimalNumber) ?? "\(pointsPerUnit)"
        return String(format: AppLocalization.localized("loyalty.preview.points_decimal_fmt", value: "%@ points"), number)
    }

    /// "1,500", grouped for the app's language.
    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLocalization.currentLocale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
