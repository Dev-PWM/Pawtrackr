import SwiftData
import SwiftUI
import OSLog

/// Loyalty runs with the visit; settings only explain it and curate rewards.
@MainActor
struct LoyaltyManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var appSettings
    @Environment(EntitlementStore.self) private var entitlements
    @Query(sort: \LoyaltyConfig.createdAt) private var configs: [LoyaltyConfig]
    @Query(sort: \LoyaltyRewardTemplate.sortOrder) private var rewards: [LoyaltyRewardTemplate]
    @State private var showNewReward = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var config: LoyaltyConfigSnapshot { LoyaltyConfigResolver.snapshot(from: configs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            LoyaltyJourneyCard()
                .walkthroughTarget(.loyaltySimulator)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LoyaltyExplainer.earning(config: config, currencySymbol: appSettings.currencySymbol))
                    Text(LoyaltyExplainer.rebook)
                    Text(LoyaltyExplainer.tiers)
                }
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            } label: {
                Text(AppLocalization.localized("loyalty.settings.program_details", value: "How points are calculated"))
                    .font(.subheadline.weight(.medium))
            }
            .tint(DS.ColorToken.primary)
            .accessibilityLabel(AppLocalization.localized("loyalty.settings.program_details", value: "How points are calculated"))

            VStack(alignment: .leading, spacing: 20) {
                Toggle(isOn: catalogEnabled) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppLocalization.localized("loyalty.settings.offer_rewards", value: "Offer rewards")).font(.headline)
                        Text(AppLocalization.localized("loyalty.settings.offer_detail", value: "A thoughtful thank-you for returning clients."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(DS.ColorToken.primary)
                .disabled(!entitlements.isPremium || isSaving)
                .accessibilityLabel(AppLocalization.localized("loyalty.settings.offer_rewards", value: "Offer rewards"))
                .accessibilityIdentifier("loyaltySettings.catalogEnabled")

                if config.isRewardsCatalogEnabled {
                    ForEach(rewards) { reward in
                        HStack(spacing: 14) {
                            Image(systemName: reward.systemImage)
                                .foregroundStyle(DS.ColorToken.primary)
                                .frame(width: 32).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LoyaltyRewardCatalog.displayTitle(for: reward.displayReward))
                                    .font(.subheadline.weight(.medium))
                                Text(LoyaltyCopy.points(reward.pointCost)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Toggle(reward.title, isOn: enabledBinding(for: reward))
                                .labelsHidden().tint(DS.ColorToken.primary)
                                .disabled(!entitlements.isPremium || isSaving)
                                .accessibilityLabel(reward.title)
                        }
                        Divider()
                    }
                    if entitlements.isPremium {
                        Button { showNewReward = true } label: {
                            Label(AppLocalization.localized("loyalty.settings.add_reward", value: "Add Reward"), systemImage: "plus")
                                .font(.subheadline.weight(.medium))
                        }
                        .pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("loyalty.settings.add_reward", value: "Add Reward"))
                        .accessibilityIdentifier("loyaltySettings.addReward")
                    }
                } else {
                    Text(AppLocalization.localized("loyalty.settings.paused_note", value: "Clients keep their points and still earn from paid visits. Turn rewards on whenever you’re ready."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 24))
            .hairlineBorder(DS.ColorToken.border, cornerRadius: 24)

            if !entitlements.isPremium {
                Label(AppLocalization.localized("loyalty.settings.pro_detail", value: "Loyalty configuration is available with active Pro access."), systemImage: "lock")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(DS.ColorToken.danger)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .sheet(isPresented: $showNewReward) { NewLoyaltyRewardSheet() }
        .task {
            do { try await LoyaltyService(modelContainer: modelContext.container).ensureDefaults() }
            catch {
                Logger.database.error("Loyalty save failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private var catalogEnabled: Binding<Bool> {
        Binding { config.isRewardsCatalogEnabled } set: { enabled in
            mutate { try await $0.updateConfig(isRewardsCatalogEnabled: enabled) }
        }
    }

    /// Only the actor's own reward model is modified, identified by UUID.
    private func enabledBinding(for reward: LoyaltyRewardTemplate) -> Binding<Bool> {
        let uuid = reward.uuid
        return Binding { reward.isEnabled } set: { enabled in
            mutate { try await $0.setRewardTemplate(uuid: uuid, isEnabled: enabled) }
        }
    }

    /// Serializes settings actions and makes persistence errors visible.
    private func mutate(_ operation: @escaping (LoyaltyService) async throws -> Void) {
        guard !isSaving, entitlements.isPremium else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await operation(LoyaltyService(modelContainer: modelContext.container))
                errorMessage = nil
            } catch {
                Logger.database.error("Loyalty save failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct NewLoyaltyRewardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var title = ""
    @State private var detail = ""
    @State private var cost = 100
    @State private var style: LoyaltyReward.Style = .credit
    @State private var creditText = "5"
    private var creditAmount: Decimal? { Formatters.parseCurrency(creditText) }
    private var validCredit: Bool { style != .credit || (creditAmount?.roundedMoney() ?? .zero) > .zero }
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField(AppLocalization.localized("loyalty.settings.reward_title_field", value: "Reward title"), text: $title)
                    .textLengthLimit($title, to: TextInputLimits.name)
                    .accessibilityLabel(AppLocalization.localized("loyalty.settings.reward_title_field", value: "Reward title"))
                TextField(AppLocalization.localized("loyalty.settings.reward_detail_field", value: "Reward detail"), text: $detail)
                    .textLengthLimit($detail, to: TextInputLimits.notes)
                    .accessibilityLabel(AppLocalization.localized("loyalty.settings.reward_detail_field", value: "Reward detail"))
                Picker(AppLocalization.localized("loyalty.settings.reward_type", value: "Reward type"), selection: $style) {
                    Text(AppLocalization.localized("loyalty.settings.credit_type", value: "Checkout credit")).tag(LoyaltyReward.Style.credit)
                    Text(AppLocalization.localized("loyalty.settings.service_type", value: "Salon service")).tag(LoyaltyReward.Style.care)
                }
                if style == .credit {
                    TextField(AppLocalization.localized("loyalty.settings.credit_value", value: "Credit amount"), text: $creditText)
                        .accessibilityLabel(AppLocalization.localized("loyalty.settings.credit_value", value: "Credit amount"))
                    Text(AppLocalization.localized("loyalty.settings.credit_note", value: "This amount is deducted automatically when selected at checkout."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(LoyaltyCopy.points(cost), value: $cost, in: 1...10_000, step: 25)
                    .accessibilityLabel(AppLocalization.localized("loyalty.settings.cost", value: "Cost"))
                if let errorMessage { Text(errorMessage).foregroundStyle(DS.ColorToken.danger) }
            }
            .navigationTitle(AppLocalization.localized("loyalty.settings.add_reward", value: "Add Reward"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("common.cancel", value: "Cancel")) { dismiss() }
                        .pressScaleStyle().disabled(isSaving)
                        .accessibilityLabel(AppLocalization.localized("common.cancel", value: "Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("common.save", value: "Save")) { save() }
                        .pressScaleStyle().disabled(title.trimmed.isEmpty || !validCredit || isSaving)
                        .accessibilityLabel(AppLocalization.localized("common.save", value: "Save"))
                }
            }
            .disabled(isSaving)
        }
        #if os(macOS)
        .frame(width: 500, height: 480)
        #endif
    }

    /// Creates the reward away from the main actor before dismissing the editor.
    private func save() {
        guard !isSaving, !title.trimmed.isEmpty, validCredit else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await LoyaltyService(modelContainer: modelContext.container).createRewardTemplate(
                    title: title.trimmed, detail: detail.trimmed, pointCost: cost, systemImage: "gift", style: style,
                    creditAmount: style == .credit ? creditAmount : nil)
                dismiss()
            } catch {
                Logger.database.error("Loyalty save failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }
}
