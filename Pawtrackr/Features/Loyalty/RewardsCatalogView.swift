import SwiftData
import SwiftUI
import OSLog

@MainActor
struct RewardsCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let client: Client
    @Query(sort: \LoyaltyRewardTemplate.sortOrder) private var templates: [LoyaltyRewardTemplate]
    @Query(sort: \LoyaltyConfig.createdAt) private var configs: [LoyaltyConfig]
    @State private var selectedReward: LoyaltyReward?
    @State private var redeemingRewardID: String?
    @State private var loyaltyBalance: LoyaltyBalanceState
    @State private var errorMessage: String?
    @State private var successMessage: String?

    init(client: Client) {
        self.client = client
        _loyaltyBalance = State(initialValue: LoyaltyBalanceState(points: client.loyaltyPoints))
    }

    private var balance: Int { loyaltyBalance.points }
    private var visibleRewards: [LoyaltyReward] {
        LoyaltyRewardCatalog.rewards(templates: templates, config: LoyaltyConfigResolver.snapshot(from: configs))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AppLocalization.localized("loyalty.catalog.available_balance", value: "Available Balance"))
                            .font(.caption).foregroundStyle(.secondary)
                        LoyaltyPointsBadge(client: client, scale: .prominent, balanceOverride: balance, errorMessage: loyaltyBalance.errorMessage)
                        Text(AppLocalization.localized("loyalty.catalog.simple_hint", value: "Credits are applied at final checkout. Salon services can be redeemed here. Keep points for as long as you like."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("rewardsCatalog.balance")

                    if visibleRewards.isEmpty {
                        ContentUnavailableView(AppLocalization.localized("loyalty.catalog.paused_title", value: "Rewards Paused"), systemImage: "gift",
                                               description: Text(AppLocalization.localized("loyalty.catalog.paused_detail", value: "Rewards can be re-enabled in Loyalty settings.")))
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleRewards) { reward in
                                rewardRow(reward)
                                Divider()
                            }
                        }
                    }
                    if let successMessage {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(DS.ColorToken.primary).font(.footnote)
                            .accessibilityIdentifier("rewardsCatalog.status")
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(DS.ColorToken.danger)
                            .accessibilityIdentifier("rewardsCatalog.status")
                    }
                }
                .padding(24)
            }
            .background(DS.ColorToken.background)
            .navigationTitle(AppLocalization.localized("loyalty.catalog.title", value: "Rewards Catalog"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("common.done", value: "Done")) { dismiss() }
                        .pressScaleStyle().disabled(redeemingRewardID != nil)
                        .accessibilityLabel(AppLocalization.localized("common.done", value: "Done"))
                }
            }
            .alert(AppLocalization.localized("loyalty.catalog.confirm_title", value: "Use this reward?"), isPresented: Binding(
                get: { selectedReward != nil }, set: { if !$0 { selectedReward = nil } }
            ), presenting: selectedReward) { reward in
                if reward.checkoutCreditAmount != nil {
                    Button(AppLocalization.localized("common.done", value: "Done")) { selectedReward = nil }
                } else {
                    Button(AppLocalization.localized("loyalty.catalog.redeem", value: "Redeem")) { redeem(reward) }
                }
                Button(AppLocalization.localized("common.cancel", value: "Cancel"), role: .cancel) { selectedReward = nil }
            } message: { reward in
                if reward.checkoutCreditAmount != nil {
                    Text(AppLocalization.localized("loyalty.catalog.checkout_hint", value: "Select this credit on the final checkout review. It will lower the total automatically, and points will be used only when payment is confirmed."))
                } else {
                    Text(String(format: AppLocalization.localized("loyalty.catalog.confirm_fmt", value: "%1$@ uses %2$@. Apply the reward at the salon after redeeming."), LoyaltyRewardCatalog.displayTitle(for: reward), LoyaltyCopy.points(reward.pointCost)))
                }
            }
        }
        .interactiveDismissDisabled(redeemingRewardID != nil)
        .loyaltyBalanceTracking(loyaltyBalance, clientUUID: client.uuid)
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
    }

    /// A flexible row keeps reward names readable at larger text sizes.
    private func rewardRow(_ reward: LoyaltyReward) -> some View {
        let ready = reward.isRedeemable(with: balance)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: reward.systemImage).font(.title3)
                    .foregroundStyle(DS.ColorToken.primary).frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LoyaltyRewardCatalog.displayTitle(for: reward)).font(.headline)
                    Text(LoyaltyCopy.points(reward.pointCost)).font(.caption).foregroundStyle(.secondary)
                    Text(reward.fulfillmentDescription).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Button { selectedReward = reward } label: {
                HStack {
                    if redeemingRewardID == reward.id { ProgressView().controlSize(.small) }
                    Text(ready ? (reward.checkoutCreditAmount != nil ? AppLocalization.localized("loyalty.catalog.at_checkout", value: "Use at checkout") : AppLocalization.localized("loyalty.catalog.redeem", value: "Redeem"))
                         : String(format: AppLocalization.localized("loyalty.catalog.more_fmt", value: "%@ to go"), LoyaltyCopy.points(max(0, reward.pointCost - balance))))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if ready { Image(systemName: "arrow.up.right") }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .foregroundStyle(ready ? DS.ColorToken.primary : .secondary)
                .background(DS.ColorToken.primary.opacity(ready ? 0.09 : 0.03), in: Capsule())
            }
            .buttonStyle(.plain).pressScaleStyle(hapticsEnabled: true)
            .disabled(!ready || redeemingRewardID != nil)
            .accessibilityLabel(String(format: AppLocalization.localized("loyalty.catalog.reward_accessibility_fmt", value: "%1$@, %2$@"),
                                      reward.checkoutCreditAmount != nil ? AppLocalization.localized("loyalty.catalog.at_checkout", value: "Use at checkout") : AppLocalization.localized("loyalty.catalog.redeem", value: "Redeem"), LoyaltyRewardCatalog.displayTitle(for: reward)))
            .accessibilityIdentifier("rewardsCatalog.reward.\(reward.id).redeem")
        }
        .padding(.vertical, 20)
    }

    /// Revalidates the reward and balance on the actor before committing one redemption.
    private func redeem(_ reward: LoyaltyReward) {
        guard redeemingRewardID == nil, reward.checkoutCreditAmount == nil else { return }
        selectedReward = nil
        redeemingRewardID = reward.id
        errorMessage = nil
        successMessage = nil
        Task {
            defer { redeemingRewardID = nil }
            do {
                let updatedBalance = try await LoyaltyService(modelContainer: modelContext.container)
                    .redeemReward(clientUUID: client.uuid, reward: reward)
                withAnimation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion)) {
                    loyaltyBalance.acceptCommittedBalance(updatedBalance)
                    successMessage = String(format: AppLocalization.localized("loyalty.catalog.redeemed_fmt", value: "Redeemed %@"), LoyaltyRewardCatalog.displayTitle(for: reward))
                }
                HapticManager.notify(.success)
            } catch {
                Logger.database.error("Loyalty operation failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                HapticManager.notify(.error)
            }
        }
    }
}
