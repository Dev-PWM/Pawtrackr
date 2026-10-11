import SwiftData
import SwiftUI

@MainActor
struct ClientLoyaltyView: View {
    let client: Client
    @Query private var ledgerEntries: [LoyaltyLedgerEntry]
    @Query(sort: \LoyaltyRewardTemplate.sortOrder) private var templates: [LoyaltyRewardTemplate]
    @Query(sort: \LoyaltyConfig.createdAt) private var configs: [LoyaltyConfig]
    @State private var showRewards = false
    @State private var showAllActivity = false
    @State private var loyaltyBalance: LoyaltyBalanceState

    init(client: Client) {
        self.client = client
        _loyaltyBalance = State(initialValue: LoyaltyBalanceState(points: client.loyaltyPoints))
        let clientUUID = client.uuid
        _ledgerEntries = Query(filter: #Predicate<LoyaltyLedgerEntry> { $0.clientUUID == clientUUID },
                               sort: [SortDescriptor(\LoyaltyLedgerEntry.createdAt, order: .reverse)])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                balance
                if let reward = featuredReward { rewardProgress(reward) }
                activity
                Text(AppLocalization.localized("loyalty.client.automatic_note", value: "Points arrive automatically after a completed, paid visit. Each award stays linked to the pet’s visit history."))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(DS.ColorToken.background)
        .navigationTitle(AppLocalization.localized("client_detail.loyalty.title", value: "Loyalty & Rewards"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showRewards) { RewardsCatalogView(client: client) }
        .loyaltyBalanceTracking(loyaltyBalance, clientUUID: client.uuid)
    }

    private var catalog: [LoyaltyReward] {
        LoyaltyRewardCatalog.rewards(templates: templates, config: LoyaltyConfigResolver.snapshot(from: configs))
            .sorted { $0.pointCost < $1.pointCost }
    }

    private var featuredReward: LoyaltyReward? {
        catalog.last { $0.isRedeemable(with: loyaltyBalance.points) }
            ?? catalog.first { $0.pointCost > loyaltyBalance.points }
    }

    private var balance: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(AppLocalization.localized("loyalty.client.visit_rewards", value: "Visit rewards"), systemImage: "sparkles")
                    .font(.subheadline.weight(.medium)).foregroundStyle(DS.ColorToken.primary)
                Spacer()
                Text(client.fullName).font(.caption).foregroundStyle(.secondary)
            }
            LoyaltyPointsBadge(client: client, scale: .prominent, balanceOverride: loyaltyBalance.points, errorMessage: loyaltyBalance.errorMessage)
            Text(loyaltyBalance.tier.displayName).font(.caption).foregroundStyle(DS.ColorToken.primary)
            Text(AppLocalization.localized("loyalty.points.keep_note", value: "Use points when you choose. They never expire, and there’s no balance limit."))
                .font(.subheadline).foregroundStyle(.secondary)
            if !catalog.isEmpty {
                Button { showRewards = true } label: {
                    HStack {
                        Text(AppLocalization.localized("loyalty.client.browse_rewards", value: "Explore rewards"))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 14).padding(.horizontal, 18)
                    .foregroundStyle(.white)
                    .background(DS.ColorToken.primary, in: Capsule())
                }
                .buttonStyle(.plain).pressScaleStyle(hapticsEnabled: true)
                .accessibilityLabel(AppLocalization.localized("loyalty.client.browse_rewards", value: "Explore rewards"))
                .accessibilityIdentifier("clientLoyalty.redeemRewards")
            }
        }
        .padding(24)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 24))
        .hairlineBorder(DS.ColorToken.border, cornerRadius: 24)
    }

    /// One reward milestone replaces the tier ladder and multiple progress cards.
    private func rewardProgress(_ reward: LoyaltyReward) -> some View {
        let ready = reward.isRedeemable(with: loyaltyBalance.points)
        return VStack(alignment: .leading, spacing: 12) {
            Text(ready
                 ? AppLocalization.localized("loyalty.client.reward_ready", value: "A reward is waiting")
                 : AppLocalization.localized("loyalty.client.next_reward", value: "Your next thank-you"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gift").foregroundStyle(DS.ColorToken.primary).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LoyaltyRewardCatalog.displayTitle(for: reward)).font(.headline)
                    Text(ready
                         ? AppLocalization.localized("loyalty.client.ready_detail", value: "Choose it from rewards whenever you’re ready.")
                         : String(format: AppLocalization.localized("loyalty.client.remaining_fmt", value: "%@ to go. Keep visiting; we’ll keep count."), LoyaltyCopy.points(max(0, reward.pointCost - loyaltyBalance.points))))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ProgressView(value: min(1, max(0, Double(loyaltyBalance.points) / Double(max(1, reward.pointCost)))))
                .tint(DS.ColorToken.primary)
                .accessibilityLabel(LoyaltyRewardCatalog.displayTitle(for: reward))
        }
        .accessibilityIdentifier("clientLoyalty.rewardProgress")
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLocalization.localized("loyalty.client.activity", value: "From their visits"))
                .font(.headline)
            if ledgerEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.localized("loyalty.client.empty_title", value: "Their story starts with a visit"))
                        .font(.subheadline.weight(.medium))
                    Text(AppLocalization.localized("loyalty.client.empty_detail", value: "Check in a pet, then complete and pay for the visit. Earned points will appear here automatically."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(showAllActivity ? ledgerEntries : Array(ledgerEntries.prefix(6))) { entry in
                        LoyaltyActivityRow(entry: entry)
                        Divider()
                    }
                }
                if ledgerEntries.count > 6 && !showAllActivity {
                    Button(AppLocalization.localized("loyalty.client.all_activity", value: "See all activity")) { showAllActivity = true }
                        .font(.subheadline).pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("loyalty.client.all_activity", value: "See all activity"))
                }
            }
        }
    }
}

private struct LoyaltyActivityRow: View {
    let entry: LoyaltyLedgerEntry

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: entry.kind == .earned ? "checkmark.circle" : "gift")
                .foregroundStyle(DS.ColorToken.primary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(entry.points > 0 ? "+\(entry.points)" : "\(entry.points)")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(entry.points > 0 ? DS.ColorToken.primary : .secondary)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch entry.kind {
        case .earned:
            entry.reason.map { String(format: AppLocalization.localized("loyalty.activity.visit_fmt", value: "%@’s visit"), $0) }
                ?? AppLocalization.localized("loyalty.activity.completed", value: "Completed visit")
        case .redeemed:
            entry.reason.map { String(format: AppLocalization.localized("loyalty.activity.redeemed_fmt", value: "Redeemed %@"), $0) }
                ?? AppLocalization.localized("loyalty.ledger.redeemed", value: "Reward redeemed")
        case .adjusted:
            AppLocalization.localized("loyalty.activity.previous_adjustment", value: "Previous balance correction")
        }
    }
}
