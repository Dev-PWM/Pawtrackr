import SwiftData
import SwiftUI

@MainActor
struct ClientLoyaltyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let client: Client
    @Query private var ledgerEntries: [LoyaltyLedgerEntry]
    @Query(sort: \LoyaltyRewardTemplate.sortOrder) private var templates: [LoyaltyRewardTemplate]
    @Query(sort: \LoyaltyConfig.createdAt) private var configs: [LoyaltyConfig]
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
                if let reward = nextReward ?? catalog.last {
                    rewardProgress(reward, allUnlocked: nextReward == nil)
                } else {
                    Label(AppLocalization.localized("loyalty.client.rewards_paused", value: "Rewards are unavailable right now. Saved points remain in this account."), systemImage: "gift")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 18))
                }
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
        .loyaltyBalanceTracking(loyaltyBalance, clientUUID: client.uuid)
    }

    private var catalog: [LoyaltyReward] {
        LoyaltyRewardCatalog.rewards(templates: templates, config: LoyaltyConfigResolver.snapshot(from: configs))
            .sorted { $0.pointCost < $1.pointCost }
    }

    private var nextReward: LoyaltyReward? {
        catalog.first { $0.pointCost > loyaltyBalance.points }
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
            Text(AppLocalization.localized("loyalty.points.keep_note", value: "Use points when you choose. They never expire, and there’s no balance limit."))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 24))
        .hairlineBorder(DS.ColorToken.border, cornerRadius: 24)
    }

    /// One reward milestone replaces the tier ladder and multiple progress cards.
    private func rewardProgress(_ reward: LoyaltyReward, allUnlocked: Bool) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            Text(allUnlocked
                 ? AppLocalization.localized("loyalty.client.all_unlocked", value: "All rewards unlocked")
                 : AppLocalization.localized("loyalty.client.next_reward", value: "Your next thank-you"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityIdentifier("clientLoyalty.rewardProgress")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gift").foregroundStyle(DS.ColorToken.primary).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LoyaltyRewardCatalog.displayTitle(for: reward)).font(.headline)
                    Text(allUnlocked
                         ? AppLocalization.localized("loyalty.client.keep_growing", value: "Every reward is available. Points keep accumulating until the client chooses one at checkout.")
                         : String(format: AppLocalization.localized("loyalty.client.remaining_fmt", value: "%@ to go. Keep visiting; we’ll keep count."), LoyaltyCopy.points(max(0, reward.pointCost - loyaltyBalance.points))))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            AnimatedRewardProgressBar(currentPoints: loyaltyBalance.points, targetPoints: reward.pointCost,
                                      rewardTitle: LoyaltyRewardCatalog.displayTitle(for: reward))
        }
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
                    Button(AppLocalization.localized("loyalty.client.all_activity", value: "See all activity")) {
                        withAnimation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion)) { showAllActivity = true }
                    }
                        .font(.subheadline).pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("loyalty.client.all_activity", value: "See all activity"))
                }
            }
        }
        .animation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion), value: ledgerEntries.count)
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
            // A deleted visit's reversal carries that visit's UUID.
            if entry.visitUUID != nil, let petName = entry.reason {
                String(format: AppLocalization.localized("loyalty.activity.visit_removed_fmt", value: "%@’s visit removed"), petName)
            } else {
                AppLocalization.localized("loyalty.activity.previous_adjustment", value: "Previous balance correction")
            }
        }
    }
}
