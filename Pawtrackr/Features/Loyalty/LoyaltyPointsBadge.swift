import SwiftUI
import SwiftData
import OSLog
import Combine

/// A read-only presentation value; fetching it never writes into the cached UI model.
@Observable
@MainActor
final class LoyaltyBalanceState {
    private(set) var points: Int
    private(set) var tier: LoyaltyTier = .bronze
    private(set) var errorMessage: String?
    private var loadGeneration = 0

    init(points: Int) { self.points = points }

    /// Uses the central store facade to refresh after checkout or redemption.
    func refresh(clientUUID: UUID, container: ModelContainer) async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let committed = try await DataStoreService(container: container).fetchLoyaltyAccount(clientUUID: clientUUID)
            guard !Task.isCancelled, generation == loadGeneration, let committed else { return }
            points = committed.points
            tier = committed.tier
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            Logger.database.error("Loyalty balance refresh failed: \(error.localizedDescription)")
            errorMessage = AppLocalization.localized("loyalty.balance.refresh_error", value: "Unable to refresh points. Reopen this screen to try again.")
        }
    }

    /// Shows an actor-confirmed result immediately and invalidates older reads.
    func acceptCommittedBalance(_ points: Int) {
        loadGeneration += 1
        self.points = points
        errorMessage = nil
    }
}

private struct LoyaltyBalanceTracking: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let state: LoyaltyBalanceState
    let clientUUID: UUID

    func body(content: Content) -> some View {
        content
            .task { await state.refresh(clientUUID: clientUUID, container: modelContext.container) }
            .onReceive(NotificationCenter.default.publisher(for: .loyaltyBalanceDidChange).receive(on: DispatchQueue.main)) { notification in
                guard notification.object as? UUID == clientUUID else { return }
                Task { await state.refresh(clientUUID: clientUUID, container: modelContext.container) }
            }
    }
}

extension View {
    /// Refreshes a presentation balance when entering a screen or after a committed award.
    func loyaltyBalanceTracking(_ state: LoyaltyBalanceState, clientUUID: UUID) -> some View {
        modifier(LoyaltyBalanceTracking(state: state, clientUUID: clientUUID))
    }
}

/// Displays the committed balance with a short, accessible completion cue.
@MainActor
struct LoyaltyPointsBadge: View {
    enum Scale: Equatable { case compact, prominent }
    let client: Client
    var scale: Scale = .prominent
    var balanceOverride: Int? = nil
    var errorMessage: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var earnedDelta = 0

    private var points: Int { balanceOverride ?? client.loyaltyPoints }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if scale == .compact {
                    Image(systemName: "sparkles").font(.caption)
                }
                Text(points.formatted())
                    .font(scale == .compact ? .subheadline.weight(.semibold) : .system(.largeTitle, design: .serif).weight(.medium))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text(AppLocalization.localized("loyalty.badge.points", value: "points"))
                    .font(scale == .compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(scale == .compact ? DS.ColorToken.primary : .primary)
            if earnedDelta > 0 {
                Label(String(format: AppLocalization.localized("loyalty.badge.saved_fmt", value: "+%@ · saved from their visit"), LoyaltyCopy.points(earnedDelta)), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(DS.ColorToken.primary)
                    .transition(.opacity)
                    .accessibilityIdentifier("loyaltyPointsBadge.saved")
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(DS.ColorToken.danger)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LoyaltyCopy.points(points))
        .accessibilityIdentifier("loyaltyPointsBadge")
        .animation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion), value: points)
        .onChange(of: points) { old, new in earnedDelta = max(0, new - old) }
        .task(id: earnedDelta) {
            guard earnedDelta > 0 else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            withAnimation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion)) { earnedDelta = 0 }
        }
    }
}

/// The original award lives on the visit, so history can explain the balance.
struct VisitLoyaltyReceipt: View {
    let visit: Visit
    var body: some View {
        if visit.endedAt != nil, visit.isPaid {
            if let title = visit.loyaltyRewardTitle, visit.loyaltyRedeemedPoints > 0 {
                Label(String(format: AppLocalization.localized("loyalty.visit.redeemed_fmt", value: "%@ · %@ used"), title, LoyaltyCopy.points(visit.loyaltyRedeemedPoints)), systemImage: "gift")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("visit.loyaltyReward")
            }
            if visit.loyaltyPointsChange > 0 {
            Label(String(format: AppLocalization.localized("loyalty.visit.earned_fmt", value: "+%@ earned"), LoyaltyCopy.points(visit.loyaltyPointsChange)), systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(DS.ColorToken.primary)
                .accessibilityIdentifier("visit.loyaltyPoints")
            }
        }
    }
}
