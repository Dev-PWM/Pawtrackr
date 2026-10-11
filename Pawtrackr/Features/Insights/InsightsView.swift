//
//  InsightsView.swift
//  Pawtrackr
//

import SwiftUI
import Charts
import SwiftData
import CoreTransferable
import OSLog

private struct InsightsDrilldown: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let summary: String
    let rows: [InsightsDrilldownRow]
}

private struct InsightsDrilldownRow: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let trailing: String
}

/// Pure gate for the Insights premium lock (unit-tested): analytics are part of
/// Pawtrackr Pro, so an explicit `.notEntitled` locks the surface. `.unknown`
/// (the brief window before StoreKit resolves at launch) stays unlocked so
/// paying users never see a lock flash — mirroring RootView's launch paywall.
/// The guided tour also bypasses the lock: it walks these charts on demo data
/// and is the pitch that sells the subscription.
enum InsightsAccessPolicy {
    static func isLocked(status: EntitlementStore.Status, isWalkthroughActive: Bool) -> Bool {
        status == .notEntitled && !isWalkthroughActive
    }
}

struct InsightsView: View {
    @Environment(DataStoreService.self) private var dataStore
    @Environment(GlobalEventBus.self) private var eventBus
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Present only while a guided tour is running; used to scroll deep-dive
    /// targets into view. Optional so previews / non-tour contexts don't require it.
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    @State private var viewModel: InsightsViewModel?
    @State private var reportExports: InsightsViewModel.ReportExports?
    @State private var isPreparingReport = false
    @State private var selectedDrilldown: InsightsDrilldown?
    @State private var selectedRevenueDate: Date?
    @State private var showProPaywall = false

    private var isProLocked: Bool {
        InsightsAccessPolicy.isLocked(
            status: entitlements.status,
            isWalkthroughActive: walkthrough?.isActive == true
        )
    }

    var body: some View {
        Group {
            if isProLocked {
                lockedContent
                    .transition(.opacity)
            } else if let vm = viewModel {
                switch vm.state {
                case .loading:
                    loadingContent
                        .transition(.opacity)
                case .loaded:
                    mainContent(vm)
                        .transition(.opacity)
                case .error(let message):
                    ContentUnavailableView(
                        NSLocalizedString("common.error", comment: ""),
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            } else {
                Color.clear
                    .task {
                        guard viewModel == nil else { return }
                        let vm = InsightsViewModel(dataStore: dataStore, eventBus: eventBus)
                        viewModel = vm
                        await vm.refresh()
                    }
            }
        }
        .background {
            InsightsMeshBackground()
                .allowsHitTesting(false)
        }
        .navigationTitle(NSLocalizedString("insights.title", value: "Insights", comment: ""))
        // A prepared report holds the numbers from when it was made. Drop it
        // when they or the salon's name change, so Export makes a new one.
        .onChange(of: viewModel?.totalRevenue) { reportExports = nil }
        .onChange(of: viewModel?.totalVisitsInPeriod) { reportExports = nil }
        .onChange(of: appSettings.businessName) { reportExports = nil }
        .refreshable {
            await viewModel?.refresh()
        }
        .sheet(item: $selectedDrilldown) { drilldown in
            drilldownSheet(drilldown)
        }
        .sheet(isPresented: $showProPaywall) {
            proPaywallSheet
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !isProLocked {
                    reportButton
                }
            }
        }
        .motionAnimation(MotionSystem.fastEaseOut, value: isProLocked)
        .privacyBlur()
    }

    // MARK: - Pro lock

    /// Shown instead of the analytics when there is no active Pro entitlement.
    /// Reaching this screen is a conversion moment, so it explains what unlocks
    /// and opens the paywall directly.
    private var lockedContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.orange.gradient)
                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                    .padding(.top, 48)

                Text(localized("insights.locked.title", value: "Insights is part of Pawtrackr Pro"))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)

                Text(localized(
                    "insights.locked.subtitle",
                    value: "Subscribe to turn your completed checkouts into live business analytics — no spreadsheets required."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

                VStack(alignment: .leading, spacing: 14) {
                    lockedFeatureRow(
                        icon: "dollarsign.circle.fill", tint: DS.ColorToken.primary,
                        text: localized("insights.locked.feature.revenue", value: "Revenue trends over 7, 30, and 90 days plus month-by-month performance.")
                    )
                    lockedFeatureRow(
                        icon: "scissors", tint: .green,
                        text: localized("insights.locked.feature.services", value: "Service profitability, payment mix, and returning-client retention.")
                    )
                    lockedFeatureRow(
                        icon: "square.and.arrow.up", tint: .blue,
                        text: localized("insights.locked.feature.export", value: "Exportable PDF and CSV reports for bookkeeping.")
                    )
                }
                .padding(18)
                .frame(maxWidth: 460)
                .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    showProPaywall = true
                } label: {
                    Label(
                        localized("insights.locked.cta", value: "Unlock with Pawtrackr Pro"),
                        systemImage: "lock.open.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .pressScaleStyle(hapticsEnabled: true)
                .accessibilityIdentifier("insights.locked.unlock")
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.lg)
        }
        .accessibilityIdentifier("insights.locked")
    }

    private func lockedFeatureRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var proPaywallSheet: some View {
        // Re-inject the store: @Observable environment values don't reliably
        // reach sheet content (macOS especially — see CommunicationSheet fix).
        #if os(macOS)
        SubscriptionPaywallView()
            .environment(entitlements)
            .frame(minWidth: 560, minHeight: 620)
        #else
        SubscriptionPaywallView()
            .environment(entitlements)
        #endif
    }

    // MARK: - Main content

    /// Insights cards the deep-dive tour can scroll to and spotlight.
    private static let walkthroughAnchors: Set<WalkthroughAnchorID> =
        [.insKpis, .insRevenue, .insMonthly, .insServices, .insPaymentMix, .insCategory]

    private func mainContent(_ vm: InsightsViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: DS.Spacing.xl) {
                    kpiSummaryRow(vm).walkthroughTarget(.insKpis)
                    revenueCard(vm).walkthroughTarget(.insRevenue)
                    if !vm.dataQualityIssues.isEmpty {
                        dataQualityCard(vm)
                    }
                    monthlyPerformanceCard(vm).walkthroughTarget(.insMonthly)
                    serviceRevenueCard(vm).walkthroughTarget(.insServices)
                    paymentMixCard(vm).walkthroughTarget(.insPaymentMix)
                    categoryCard(vm).walkthroughTarget(.insCategory)
                    retentionCard(vm)
                }
                .frame(maxWidth: insightsContentMaxWidth)
                .padding(DS.Spacing.lg)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("insights.mainScroll.content")
            }
            .accessibilityIdentifier("insights.mainScroll")
            // Scroll the current deep-dive target into view as the tour advances.
            .onAppear {
                scrollToWalkthroughAnchorIfNeeded(walkthrough?.currentStep?.anchor, proxy: proxy)
            }
            .onChange(of: walkthrough?.currentStep?.anchor) { _, anchor in
                scrollToWalkthroughAnchorIfNeeded(anchor, proxy: proxy)
            }
        }
    }

    private func scrollToWalkthroughAnchorIfNeeded(_ anchor: WalkthroughAnchorID?, proxy: ScrollViewProxy) {
        guard let anchor, Self.walkthroughAnchors.contains(anchor) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    private let compactMaxWidth: CGFloat = 640
    private let regularInsightsMaxWidth: CGFloat = 1040
    private let macOSInsightsMaxWidth: CGFloat = 1180

    private var insightsContentMaxWidth: CGFloat {
        #if os(macOS)
        return macOSInsightsMaxWidth
        #else
        return horizontalSizeClass == .compact ? compactMaxWidth : regularInsightsMaxWidth
        #endif
    }

    // MARK: - KPI summary strip

    private func kpiSummaryRow(_ vm: InsightsViewModel) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            kpiTile(
                title: NSLocalizedString("insights.revenue", comment: ""),
                value: vm.totalRevenue.moneyString,
                icon: "dollarsign.circle.fill",
                color: DS.ColorToken.primary,
                accessibilityIdentifier: "insights.kpi.revenue"
            )
            kpiTile(
                title: localized("insights.avg_visit", value: "Avg Visit"),
                value: vm.averageVisitValue > 0 ? vm.averageVisitValue.moneyString : "—",
                icon: "chart.line.uptrend.xyaxis",
                color: DS.ColorToken.success,
                accessibilityIdentifier: "insights.kpi.avgVisit"
            )
            kpiTile(
                title: NSLocalizedString("insights.retention", comment: ""),
                value: "\(Int(vm.retentionRate * 100))%",
                icon: "person.2.fill",
                color: DS.ColorToken.warning,
                accessibilityIdentifier: "insights.kpi.retention"
            )
        }
    }

    private func kpiTile(
        title: String,
        value: String,
        icon: String,
        color: Color,
        accessibilityIdentifier: String
    ) -> some View {
        // Read-only summary tile. Intentionally NOT a Button: the KPI strip is a
        // clean set of visual data points, so there is no tap-to-drill-down here.
        Card(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: - Data Quality

    private func dataQualityCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Label(localized("insights.data_quality.title", value: "Data Quality"), systemImage: "checklist.checked")
                    .font(.headline)

                ForEach(vm.dataQualityIssues.prefix(4)) { issue in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: dataQualityIcon(for: issue.severity))
                            .foregroundStyle(dataQualityColor(for: issue.severity))
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                            Text(issue.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Text("\(issue.count)")
                            .font(.headline)
                            .contentTransition(.numericText())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("insights.section.dataQuality")
    }

    // MARK: - Revenue

    private func selectedRevenuePoint(in vm: InsightsViewModel) -> InsightsViewModel.RevenueData? {
        guard let selectedRevenueDate else { return nil }
        let calendar = Calendar.current
        return vm.revenueSeries.first { calendar.isDate($0.date, inSameDayAs: selectedRevenueDate) }
    }

    private func revenueCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("insights.revenue", comment: ""))
                            .font(.headline)
                        Text(String(format: localized("insights.window_days_fmt", value: "%d-day window"), vm.revenuePeriodDays))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("insights.revenue.window")
                            .accessibilityValue(String(format: localized("insights.window_days_fmt", value: "%d-day window"), vm.revenuePeriodDays))
                    }
                    Spacer()
                    revenuePeriodSelector(vm)
                }

                Text(vm.totalRevenue.moneyString)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.ColorToken.primary)
                    .contentTransition(.numericText())

                if vm.revenueSeries.isEmpty || vm.totalRevenue == .zero {
                    emptyState(icon: "chart.bar.xaxis", message: localized("insights.revenue.empty", value: "No revenue recorded in this period"))
                } else {
                    if let selected = selectedRevenuePoint(in: vm) {
                        Text("\(selected.date.formatted(.dateTime.weekday(.wide))): \(selected.amount.moneyString)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DS.ColorToken.primary)
                            .transition(.opacity)
                            .accessibilityIdentifier("insights.revenue.selected")
                    }

                    Chart(vm.revenueSeries) { data in
                        BarMark(
                            x: .value(localized("insights.chart.day", value: "Day"), data.date, unit: .day),
                            y: .value(NSLocalizedString("insights.revenue", comment: ""), (data.amount as NSDecimalNumber).doubleValue)
                        )
                        .foregroundStyle(DS.ColorToken.primary.gradient)
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: vm.revenuePeriodDays <= 7 ? 1 : vm.revenuePeriodDays <= 30 ? 5 : 15)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 9))
                            AxisGridLine()
                        }
                    }
                    .chartXSelection(value: $selectedRevenueDate)
                    .frame(height: 155)
                    // Scrubbing previews individual days; reconciliation remains
                    // available through the explicit visit drilldown button below.
                    .animation(.spring(), value: vm.revenueSeries.count)
                    .animation(.spring(response: 0.35, dampingFraction: 0.82), value: selectedRevenueDate)

                    HStack {
                        Label(String(format: localized("insights.visits_count_fmt", value: "%d visits"), vm.totalVisitsInPeriod), systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label(
                            String(format: localized("insights.avg_money_fmt", value: "Avg %@"), vm.averageVisitValue.moneyString),
                            systemImage: "chart.line.uptrend.xyaxis"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("insights.section.revenue")
    }

    private func revenuePeriodSelector(_ vm: InsightsViewModel) -> some View {
        let periods: [Int] = [7, 30, 90]
        return HStack(spacing: 4) {
            ForEach(periods, id: \.self) { period in
                let isSelected = vm.revenuePeriodDays == period
                Button {
                    guard vm.revenuePeriodDays != period else { return }
                    withAnimation(Animations.responsiveSpringSoft) {
                        vm.revenuePeriodDays = period
                        selectedRevenueDate = nil
                    }
                    reportExports = nil
                    Task { await vm.refreshRevenue() }
                    // The Academy's period mission: let the chart redraw first.
                    if walkthrough?.currentStep?.advancesOn == .insightsPeriodChanged {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(900))
                            walkthrough?.observe(.insightsPeriodChanged)
                        }
                    }
                } label: {
                    Text("\(period)D")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(minWidth: 34)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(isSelected ? DS.ColorToken.primary : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("insights.period.\(period)")
            }
        }
        .padding(4)
        .background(DS.ColorToken.surface, in: Capsule())
    }

    // MARK: - Monthly Performance

    private func monthlyPerformanceCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(localized("insights.monthly_performance", value: "Monthly Performance")).font(.headline)

                if vm.monthlyGrowth.isEmpty {
                    emptyState(icon: "chart.line.uptrend.xyaxis", message: localized("insights.monthly.empty", value: "No monthly data yet"))
                } else {
                    Chart(vm.monthlyGrowth) { data in
                        LineMark(
                            x: .value("Month", data.month),
                            y: .value("Revenue", (data.revenue as NSDecimalNumber).doubleValue)
                        )
                        .foregroundStyle(DS.ColorToken.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .symbol(Circle().strokeBorder(lineWidth: 2))
                        
                        AreaMark(
                            x: .value("Month", data.month),
                            y: .value("Revenue", (data.revenue as NSDecimalNumber).doubleValue)
                        )
                        .foregroundStyle(DS.ColorToken.primary.opacity(0.1))
                    }
                    .frame(height: 155)

                    Divider()

                    HStack(spacing: 0) {
                        ForEach(vm.monthlyGrowth.suffix(3)) { data in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(data.month).font(.caption2).foregroundStyle(.secondary)
                                Text(data.revenue.moneyString).font(.subheadline.weight(.bold))
                                Text(String(format: localized("insights.visits_count_fmt", value: "%d visits"), data.visitCount)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Service Revenue

    private func serviceRevenueCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                lowerSectionAccessibilityAnchor(identifier: "insights.section.topServices", label: NSLocalizedString("insights.top_services", comment: ""))
                Text(localized("insights.service_profitability", value: "Service Profitability")).font(.headline)

                if vm.serviceProfitability.isEmpty && vm.serviceDistribution.isEmpty {
                    emptyState(icon: "scissors", message: localized("insights.service_profitability.empty", value: "No service data yet"))
                } else {
                    let top5 = Array((vm.serviceProfitability.isEmpty ? vm.serviceDistribution : vm.serviceProfitability.map {
                        InsightsViewModel.DistributionData(name: $0.name, count: $0.count, revenue: $0.revenue)
                    }).prefix(5))
                    Chart(top5) { data in
                        BarMark(
                            x: .value("Revenue", (data.revenue as NSDecimalNumber).doubleValue),
                            y: .value("Service", data.name)
                        )
                        .foregroundStyle(DS.ColorToken.success.gradient)
                        .cornerRadius(4)
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(top5.count) * 44)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.section.topServices")
    }

    private func paymentMixCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                lowerSectionAccessibilityAnchor(identifier: "insights.section.paymentMix", label: localized("insights.payment_mix", value: "Payment Mix"))
                Text(localized("insights.payment_mix", value: "Payment Mix")).font(.headline)

                if vm.paymentMethodDistribution.isEmpty {
                    emptyState(icon: "creditcard", message: localized("insights.payment_mix.empty", value: "No payments recorded yet"))
                } else {
                    ForEach(vm.paymentMethodDistribution) { item in
                        HStack(spacing: 12) {
                            Label(item.method.displayName, systemImage: item.method.systemImage)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(item.amount.moneyString).font(.subheadline.weight(.bold))
                                Text(paymentCountText(item.count)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.section.paymentMix")
    }

    private func categoryCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                lowerSectionAccessibilityAnchor(identifier: "insights.section.category", label: localized("insights.visits_by_category", value: "Visits by Category"))
                Text(localized("insights.visits_by_category", value: "Visits by Category")).font(.headline)

                if vm.categoryDistribution.isEmpty {
                    emptyState(icon: "square.grid.2x2", message: localized("insights.category.empty", value: "No category data yet"))
                } else {
                    // Single source of truth: categoryColor(for:) maps each category
                    // name to a stable color, shared by the donut slices AND the
                    // breakdown dots below so a slice color maps back to its category.
                    Chart(vm.categoryDistribution) { data in
                        SectorMark(
                            angle: .value(localized("insights.chart.count", value: "Count"), data.count),
                            innerRadius: .ratio(0.6),
                            angularInset: 2
                        )
                        .cornerRadius(4)
                        .foregroundStyle(categoryColor(for: data.name))
                    }
                    .frame(height: 155)
                    .chartLegend(.hidden)
                    .overlay {
                        VStack {
                            Text("\(vm.totalCategoryVisits)").font(.headline)
                            Text(localized("insights.visits_lowercase", value: "visits")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    VStack(spacing: 0) {
                        ForEach(Array(vm.categoryDistribution.enumerated()), id: \.element.id) { index, item in
                            categoryBreakdownRow(item, total: vm.totalCategoryVisits, color: categoryColor(for: item.name))
                            if index < vm.categoryDistribution.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.section.category")
    }

    private func retentionCard(_ vm: InsightsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                lowerSectionAccessibilityAnchor(identifier: "insights.section.retention", label: NSLocalizedString("insights.retention", comment: ""))
                Text(NSLocalizedString("insights.retention", comment: "")).font(.headline)

                if vm.retentionSeries.isEmpty {
                    emptyState(icon: "person.2", message: localized("insights.retention.empty", value: "Not enough client data yet"))
                } else {
                    HStack(spacing: 30) {
                        Chart(vm.retentionSeries) { data in
                            SectorMark(angle: .value("Value", data.value), innerRadius: .ratio(0.7))
                                .foregroundStyle(data.label == localized("insights.retention.recurring", value: "Recurring") ? DS.ColorToken.primary : Color.gray.opacity(0.2))
                        }
                        .frame(width: 100, height: 100)
                        .chartLegend(.hidden)
                        .overlay {
                            Text("\(Int(vm.retentionRate * 100))%").font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            metricLabel(title: NSLocalizedString("insights.retention_rate", comment: ""), value: "\(Int(vm.retentionRate * 100))%", color: DS.ColorToken.primary)
                            metricLabel(title: NSLocalizedString("insights.churn_risk", comment: ""), value: String(format: localized("insights.clients_count_fmt", value: "%d clients"), vm.churnRiskCount), color: DS.ColorToken.warning)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.section.retention")
    }

    private func metricLabel(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).foregroundStyle(color)
        }
    }

    private func categoryBreakdownRow(_ item: InsightsViewModel.DistributionData, total: Int, color: Color) -> some View {
        let percent = total > 0 ? Int((Double(item.count) / Double(total) * 100).rounded()) : 0
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(color)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                Text(String(format: localized("insights.category.row_detail_fmt", value: "%d%% of categorized visit line items"), percent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: localized("insights.visits_count_fmt", value: "%d visits"), item.count))
                .font(.subheadline.weight(.bold))
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func categoryColor(for name: String) -> Color {
        switch name {
        case Service.Category.package.rawValue:
            return DS.ColorToken.info
        case Service.Category.addOn.rawValue:
            return DS.ColorToken.warning
        case Service.Category.groom.rawValue:
            return DS.ColorToken.success
        case Service.Category.care.rawValue:
            return Color.purple
        default:
            return Color.gray
        }
    }

    private func paymentCountText(_ count: Int) -> String {
        count == 1 ? "1 payment" : "\(count) payments"
    }

    private func lowerSectionAccessibilityAnchor(identifier: String, label: String) -> some View {
        Color.primary.opacity(0.001)
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private var reportButton: some View {
        Group {
            if let exports = reportExports {
                Menu {
                    ShareLink(item: exports.pdf, preview: SharePreview(exports.pdf.filename)) {
                        Label(localized("insights.export.pdf_report", value: "PDF Report"), systemImage: "doc.richtext")
                    }
                    ShareLink(item: exports.csv, preview: SharePreview(exports.csv.filename)) {
                        Label(localized("insights.export.csv_data", value: "Owner Insights CSV"), systemImage: "tablecells")
                    }
                } label: {
                    Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel(localized("insights.export.share_report", value: "Share Report"))
                .accessibilityIdentifier("insights.shareReport")
            } else {
                Button {
                    isPreparingReport = true
                    Task {
                        if let vm = viewModel {
                            let period = vm.revenuePeriodDays
                            do {
                                let exports = try await vm.makeReportExports(
                                    businessName: appSettings.businessName,
                                    currencySymbol: appSettings.currencySymbol
                                )
                                // The period changed while it was being made.
                                if vm.revenuePeriodDays == period {
                                    reportExports = exports
                                }
                            } catch {
                                Logger.insightsExport.error("Report export failed: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                        isPreparingReport = false
                    }
                }
 label: {
                    if isPreparingReport { ProgressView() } else { Label(NSLocalizedString("common.export", comment: ""), systemImage: "doc.badge.arrow.up") }
                }
                .disabled(isPreparingReport)
                .accessibilityLabel(localized("insights.export.export_report", value: "Export Report"))
                .accessibilityIdentifier("insights.exportReport")
            }
        }
    }

    private func drilldownSheet(_ drilldown: InsightsDrilldown) -> some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(drilldown.summary)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text(localized("insights.drilldown.what_this_means", value: "What this means"))
                }

                Section {
                    if drilldown.rows.isEmpty {
                        ContentUnavailableView(
                            localized("insights.drilldown.no_rows_title", value: "No Rows"),
                            systemImage: "list.bullet.rectangle",
                            description: Text(localized("insights.drilldown.no_rows_message", value: "There is no supporting data for this selection yet."))
                        )
                    } else {
                        ForEach(drilldown.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(row.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(row.trailing)
                                    .font(.subheadline.bold())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: {
                    Text(drilldown.subtitle)
                }
            }
            .navigationTitle(drilldown.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.done", comment: "")) { selectedDrilldown = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title).foregroundStyle(.secondary.opacity(0.3))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 120)
    }

    private func showRevenueDrilldown(_ vm: InsightsViewModel) {
        selectedDrilldown = InsightsDrilldown(
            title: localized("insights.drilldown.revenue_title", value: "Revenue Detail"),
            subtitle: String(format: localized("insights.window_days_fmt", value: "%d-day window"), vm.revenuePeriodDays),
            summary: localized(
                "insights.drilldown.revenue_summary",
                value: "This lists the completed visits included in the selected revenue window. Use it to reconcile cash, card, and checkout history."
            ),
            rows: visitDrilldownRows(vm.revenueDrilldown)
        )
    }

    private func showCategoryDrilldown(_ vm: InsightsViewModel) {
        selectedDrilldown = InsightsDrilldown(
            title: localized("insights.drilldown.category_title", value: "Visit Category Detail"),
            subtitle: localized("insights.drilldown.category_subtitle", value: "Category share for completed visit line items"),
            summary: localized(
                "insights.drilldown.category_summary",
                value: "This breaks down which types of services are driving completed visits. A category can count more than once when a checkout includes multiple line items."
            ),
            rows: categoryDrilldownRows(vm.categoryDistribution, total: vm.totalCategoryVisits)
        )
    }

    private func categoryDrilldownRows(_ rows: [InsightsViewModel.DistributionData], total: Int) -> [InsightsDrilldownRow] {
        rows.map { item in
            let percent = total > 0 ? Int((Double(item.count) / Double(total) * 100).rounded()) : 0
            return InsightsDrilldownRow(
                title: item.name,
                subtitle: String(format: localized("insights.category.row_detail_fmt", value: "%d%% of categorized visit line items"), percent),
                trailing: String(format: localized("insights.visits_count_fmt", value: "%d visits"), item.count)
            )
        }
    }

    private func visitDrilldownRows(_ rows: [InsightsViewModel.RevenueVisitData]) -> [InsightsDrilldownRow] {
        rows.map {
            InsightsDrilldownRow(
                title: "\($0.petName) • \($0.clientName)",
                subtitle: "\($0.date.formatted(date: .abbreviated, time: .omitted)) • \($0.serviceSummary) • \($0.paymentMethod)",
                trailing: $0.total.moneyString
            )
        }
    }

    private func percentString(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(Int((value * 100).rounded()))%"
    }

    private func localized(_ key: String, value: String) -> String {
        NSLocalizedString(key, value: value, comment: "")
    }

    private func dataQualityIcon(for severity: InsightsViewModel.DataQualityIssue.Severity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func dataQualityColor(for severity: InsightsViewModel.DataQualityIssue.Severity) -> Color {
        switch severity {
        case .info: return DS.ColorToken.primary
        case .warning: return DS.ColorToken.warning
        case .critical: return DS.ColorToken.danger
        }
    }

    // MARK: - Skeleton / Loading

    private var loadingContent: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(0..<3) { _ in SkeletonRect().frame(height: 90) }
                }
                
                // Chart Skeletons
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonRect().frame(width: 150, height: 20)
                    SkeletonChart(type: .bar).frame(height: 160)
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonRect().frame(width: 180, height: 20)
                    SkeletonChart(type: .line).frame(height: 160)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SkeletonRect().frame(width: 140, height: 20)
                    SkeletonChart(type: .pie).frame(height: 160)
                }
            }
            .padding(DS.Spacing.lg)
        }
    }
}

enum SkeletonChartType { case bar, line, pie }

struct SkeletonChart: View {
    let type: SkeletonChartType

    // Fixed heights so the skeleton is stable across re-renders.
    // CGFloat.random in a view body causes layout thrashing on every redraw.
    private static let barHeights: [CGFloat] = [85, 55, 110, 70, 95, 45, 120, 65, 80, 50]

    var body: some View {
        Card {
            HStack(alignment: .bottom, spacing: 8) {
                if type == .bar {
                    ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                        SkeletonRect()
                            .frame(height: height)
                    }
                } else if type == .line {
                    ZStack {
                        SkeletonRect().opacity(0.1)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 100))
                            path.addLine(to: CGPoint(x: 50, y: 40))
                            path.addLine(to: CGPoint(x: 100, y: 80))
                            path.addLine(to: CGPoint(x: 150, y: 20))
                            path.addLine(to: CGPoint(x: 200, y: 60))
                        }
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                    }
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 20)
                        .frame(width: 100, height: 100)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(10)
        }
    }
}

private extension Logger {
    static let insightsExport = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "InsightsExport")
}
