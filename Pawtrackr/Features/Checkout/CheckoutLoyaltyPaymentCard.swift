import SwiftUI

/// Optional redemption beside payment entry. All choices belong to the checkout view model.
struct CheckoutLoyaltyPaymentCard: View {
    @Bindable var viewModel: CheckoutViewModel
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label(AppLocalization.localized("checkout.loyalty.title", value: "Visit rewards"), systemImage: "sparkles")
                    .font(.headline)
                Spacer(minLength: 12)
                Text(viewModel.loyaltyTier.displayName).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(viewModel.loyaltyPoints.formatted()).font(.system(.title, design: .serif)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(AppLocalization.localized("checkout.loyalty.saved_points", value: "saved points"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("checkout.loyalty.balance")

            if let reward = viewModel.selectedLoyaltyReward {
                VStack(alignment: .leading, spacing: 5) {
                    Label(LoyaltyRewardCatalog.displayTitle(for: reward), systemImage: "gift")
                        .font(.subheadline.weight(.medium))
                    Text(String(format: AppLocalization.localized("checkout.loyalty.use_fmt", value: "Use %@ from the saved balance"), LoyaltyCopy.points(reward.pointCost)))
                        .font(.footnote).foregroundStyle(.secondary)
                    if viewModel.loyaltyCredit > .zero {
                        Text(String(format: AppLocalization.localized("checkout.loyalty.credit_fmt", value: "%@ off this visit"), viewModel.loyaltyCredit.moneyString))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(DS.ColorToken.primary)
                    } else {
                        Text(reward.fulfillmentDescription).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("checkout.loyalty.selectedReward")
                Button(AppLocalization.localized("checkout.loyalty.keep", value: "Keep points for later")) { viewModel.chooseLoyaltyReward(nil) }
                    .pressScaleStyle().accessibilityIdentifier("checkout.loyalty.keep")
                    .accessibilityLabel(AppLocalization.localized("checkout.loyalty.keep", value: "Keep points for later"))
                if !viewModel.isLoyaltySelectionValid && !viewModel.isLoadingLoyalty {
                    Text(AppLocalization.localized("checkout.loyalty.rechoose", value: "This choice has changed. Choose a reward again or keep your points."))
                        .font(.footnote).foregroundStyle(DS.ColorToken.danger)
                }
            } else {
                Label(AppLocalization.localized("checkout.loyalty.keep", value: "Keep points for later"), systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(DS.ColorToken.primary)
                    .accessibilityIdentifier("checkout.loyalty.kept")
            }
            Button {
                onChoose()
            } label: {
                HStack {
                    Text(AppLocalization.localized("checkout.loyalty.choose", value: "Choose a reward"))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(DS.ColorToken.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain).pressScaleStyle()
            .accessibilityLabel(AppLocalization.localized("checkout.loyalty.choose", value: "Choose a reward"))
            .accessibilityIdentifier("checkout.loyalty.choose")
            .disabled(viewModel.isLoadingLoyalty || viewModel.isSaving)
            if viewModel.isLoadingLoyalty {
                ProgressView()
            } else if viewModel.loyaltyRewards.isEmpty && viewModel.loyaltyError == nil {
                Text(AppLocalization.localized("checkout.loyalty.no_rewards", value: "No rewards are configured yet. Add a reward in Loyalty settings."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(AppLocalization.localized("loyalty.points.keep_note", value: "Use points when you choose. They never expire, and there’s no balance limit."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = viewModel.loyaltyError {
                Text(error).font(.footnote).foregroundStyle(DS.ColorToken.danger)
                Button(AppLocalization.localized("common.retry", value: "Try Again")) { Task { await viewModel.refreshLoyaltyOptions() } }
                    .pressScaleStyle().accessibilityLabel(AppLocalization.localized("common.retry", value: "Try Again"))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 24))
        .hairlineBorder(DS.ColorToken.border, cornerRadius: 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkout.loyalty.card")
        .task { await viewModel.refreshLoyaltyOptions() }
    }
}

/// Choosing here is reversible and never calls a redemption persistence API.
struct CheckoutRewardSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: CheckoutViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(LoyaltyCopy.points(viewModel.loyaltyPoints)).font(.system(.title, design: .serif))
                    Text(AppLocalization.localized("checkout.loyalty.selection_note", value: "Choose one reward for this visit. Points are used only when you confirm payment."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(viewModel.loyaltyRewards) { reward in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: reward.systemImage).foregroundStyle(DS.ColorToken.primary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(LoyaltyRewardCatalog.displayTitle(for: reward)).font(.headline)
                                    Text(reward.fulfillmentDescription).font(.footnote).foregroundStyle(.secondary)
                                    if !reward.detail.isEmpty { Text(reward.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            HStack {
                                Text(LoyaltyCopy.points(reward.pointCost)).font(.subheadline)
                                Spacer(minLength: 12)
                                Button(AppLocalization.localized("checkout.loyalty.select", value: "Select")) {
                                    viewModel.chooseLoyaltyReward(reward)
                                }
                                .pressScaleStyle()
                                .accessibilityLabel(String(format: AppLocalization.localized("checkout.loyalty.select_fmt", value: "Select %@"), LoyaltyRewardCatalog.displayTitle(for: reward)))
                                .accessibilityIdentifier("checkout.reward.\(reward.id)")
                                .disabled(viewModel.isLoadingLoyalty || !reward.isRedeemable(with: viewModel.loyaltyPoints) || !reward.isApplicable(to: viewModel.servicesTotalDecimal))
                            }
                            if reward.isRedeemable(with: viewModel.loyaltyPoints), !reward.isApplicable(to: viewModel.servicesTotalDecimal) {
                                Text(AppLocalization.localized("checkout.loyalty.credit_exceeds_total", value: "This visit total is below the reward's full credit. Choose another reward or keep the points."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(20)
                        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 18))
                        .hairlineBorder(DS.ColorToken.border, cornerRadius: 18)
                    }
                    if viewModel.loyaltyRewards.isEmpty {
                        ContentUnavailableView(AppLocalization.localized("checkout.loyalty.no_rewards", value: "No rewards are configured yet. Add a reward in Loyalty settings."), systemImage: "gift")
                    }
                }
                .padding(24)
            }
            .background(DS.ColorToken.background)
            .navigationTitle(AppLocalization.localized("checkout.loyalty.choose", value: "Choose a reward"))
            .task { await viewModel.refreshLoyaltyOptions() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("common.cancel", value: "Cancel")) { dismiss() }
                        .pressScaleStyle().accessibilityLabel(AppLocalization.localized("common.cancel", value: "Cancel"))
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
    }
}
