//
//  DashboardView.swift
//  Pawtrackr
//

import SwiftUI
import SwiftData
#if canImport(Charts)
import Charts
#endif

struct DashboardView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(DataStoreService.self) private var dataStore
    @Environment(GlobalEventBus.self) private var eventBus
    @Environment(NavigationRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The practice salon's checklist never retires the real one.
    @Environment(\.isPracticeSalon) private var isPracticeSalon
    /// Present only while a guided tour is running; used to scroll deep-dive
    /// targets into view. Optional so previews / non-tour contexts don't require it.
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    @State private var vm: DashboardViewModel?
    @State private var showNewClient = false
    @State private var showQuickCheckOut = false
    @State private var selectedRevenueDate: Date?
    /// Set while the "Remove Sample Clients?" confirmation is up; it lists
    /// what will be deleted.
    @State private var sampleRemovalInventory: SampleDataInventory?
    var namespace: Namespace.ID

    var body: some View {
        dashboardContent
            .navigationTitle(NSLocalizedString("dashboard.title", comment: ""))
            .sheet(isPresented: $showNewClient) {
                NewClientSheet(modelContext: modelContext)
            }
            .sheet(isPresented: $showQuickCheckOut) {
                QuickCheckOutSheet(activeVisits: vm?.activeVisits ?? []) { visit in
                    showQuickCheckOut = false
                    router.navigateToCheckout(visit)
                }
            }
            .alert(
                SampleDataCopy.removeTitle,
                isPresented: Binding(
                    get: { sampleRemovalInventory != nil },
                    set: { if !$0 { sampleRemovalInventory = nil } }
                ),
                presenting: sampleRemovalInventory
            ) { _ in
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
                Button(SampleDataCopy.removeConfirm, role: .destructive) {
                    Task { await vm?.removeSampleData() }
                }
            } message: { inventory in
                Text(SampleDataCopy.removeMessage(for: inventory))
            }
            .alert(item: appErrorBinding) { error in
                Alert(
                    title: Text(NSLocalizedString("common.error", comment: "")),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "")))
                )
            }
            .toolbar { insightsToolbarItem }
            .privacyBlur()
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if let vm {
            switch vm.state {
            case .loading:
                skeletonView
                    .transition(.opacity)
            case .loaded:
                content(vm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                    guard self.vm == nil else { return }
                    vm = DashboardViewModel(dataStore: dataStore, eventBus: eventBus)
                }
        }
    }

    private var appErrorBinding: Binding<AppError?> {
        Binding(get: { vm?.appError }, set: { vm?.appError = $0 })
    }

    @ToolbarContentBuilder
    private var insightsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showNewClient = true
            } label: {
                Label(NSLocalizedString("dashboard.new_client", comment: ""), systemImage: "person.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        // No toolbar Refresh: the dashboard reloads itself when data changes.
    }

    /// Dashboard sections the deep-dive tour can scroll to and spotlight.
    private static let walkthroughAnchors: Set<WalkthroughAnchorID> =
        [.setupChecklist, .dashKpis, .dashQuickActions, .dashNeedsAttention, .dashRecentClients, .dashRevenue]

    @ViewBuilder
    private func content(_ vm: DashboardViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    smartSummary(vm)

                    if shouldShowChecklistSection(vm) {
                        checklistSection(vm)
                            .walkthroughTarget(.setupChecklist)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: dashboardColumnSpacing) {
                            VStack(spacing: 24) {
                                kpiSection(vm).walkthroughTarget(.dashKpis)
                                if !vm.activeVisits.isEmpty { activeSessionsSection(vm) }
                                reengagementSection(vm)
                                revenueSection(vm).walkthroughTarget(.dashRevenue)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 24) {
                                quickActionsSection.walkthroughTarget(.dashQuickActions)
                                if shouldShowNeedsAttentionSection(vm) { overduePetsSection(vm).walkthroughTarget(.dashNeedsAttention) }
                                if shouldShowRecentClientsSection(vm) { recentClientsSection(vm).walkthroughTarget(.dashRecentClients) }
                            }
                            .frame(width: dashboardSideColumnWidth)
                        }

                        VStack(spacing: 24) {
                            kpiSection(vm).walkthroughTarget(.dashKpis)
                            quickActionsSection.walkthroughTarget(.dashQuickActions)
                            if !vm.activeVisits.isEmpty { activeSessionsSection(vm) }
                            reengagementSection(vm)
                            if shouldShowNeedsAttentionSection(vm) { overduePetsSection(vm).walkthroughTarget(.dashNeedsAttention) }
                            if shouldShowRecentClientsSection(vm) { recentClientsSection(vm).walkthroughTarget(.dashRecentClients) }
                            revenueSection(vm).walkthroughTarget(.dashRevenue)
                        }
                    }
                }
                .frame(maxWidth: dashboardContentMaxWidth, alignment: .top)
                .padding(.horizontal, dashboardHorizontalPadding)
                .padding(.vertical, dashboardVerticalPadding)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("dashboard.scroll")
            // Once every local setup row is done, retire the card.
            // Replay and Start Fresh re-arm it.
            .onChange(of: vm.isChecklistComplete, initial: true) { _, isComplete in
                if isComplete && !isPracticeSalon && !appSettings.isChecklistDismissed {
                    appSettings.isChecklistDismissed = true
                }
            }
            .refreshable {
                await vm.refresh()
            }
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

    // MARK: - Skeleton View
    private var skeletonView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Smart Summary Skeleton
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonRect().frame(width: 150, height: 24)
                    SkeletonRect().frame(maxWidth: .infinity).frame(height: 16)
                    SkeletonRect().frame(width: 200, height: 16)
                }
                .padding(.bottom, 8)

                // KPI Skeleton
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        SkeletonRect().frame(height: 80)
                        SkeletonRect().frame(height: 80)
                    }
                    GridRow {
                        SkeletonRect().frame(height: 80)
                        SkeletonRect().frame(height: 80)
                    }
                }

                // Quick Actions Skeleton
                HStack(spacing: 12) {
                    ForEach(0..<3) { _ in
                        SkeletonRect().frame(width: 130, height: 100)
                    }
                }

                // List Skeleton
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonRect().frame(width: 120, height: 20)
                    ForEach(0..<3) { _ in
                        SkeletonRect().frame(height: 120)
                    }
                }
            }
            .padding(16)
        }
    }

    private func isWalkthroughSpotlighting(_ anchor: WalkthroughAnchorID) -> Bool {
        walkthrough?.isActive == true && walkthrough?.currentStep?.anchor == anchor
    }

    /// The Getting Started card shows while it has unfinished rows and hasn't
    /// been closed, and also while the tour points at it, so its stop always
    /// has the real card to show. An empty checklist (still loading) never shows.
    private func shouldShowChecklistSection(_ vm: DashboardViewModel) -> Bool {
        guard !vm.checklist.isEmpty else { return false }
        return isWalkthroughSpotlighting(.setupChecklist)
            || (!appSettings.isChecklistDismissed && !vm.isChecklistComplete)
    }

    private func shouldShowNeedsAttentionSection(_ vm: DashboardViewModel) -> Bool {
        !vm.overduePets.isEmpty || isWalkthroughSpotlighting(.dashNeedsAttention)
    }

    private func shouldShowRecentClientsSection(_ vm: DashboardViewModel) -> Bool {
        !vm.recentClients.isEmpty || isWalkthroughSpotlighting(.dashRecentClients)
    }

    private var dashboardVerticalPadding: CGFloat {
        #if os(macOS)
        return 24
        #else
        return horizontalSizeClass == .compact ? 16 : 24
        #endif
    }

    private var dashboardContentMaxWidth: CGFloat {
        #if os(macOS)
        return 1260
        #else
        return horizontalSizeClass == .compact ? 640 : 1180
        #endif
    }

    private var dashboardHorizontalPadding: CGFloat {
        #if os(macOS)
        return 24
        #else
        return horizontalSizeClass == .compact ? 16 : 24
        #endif
    }

    private var dashboardColumnSpacing: CGFloat {
        #if os(macOS)
        return 20
        #else
        return 24
        #endif
    }

    private var dashboardSideColumnWidth: CGFloat {
        #if os(macOS)
        return 350
        #else
        return 360
        #endif
    }

    // MARK: - Sections (unchanged logic, just ensuring they use the VM)

    private func suggestionCard(_ suggestion: SmartSuggestion) -> some View {
        Card(elevation: .regular, accent: .leading(.color(.purple), thickness: 4)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(suggestion.petName).font(.subheadline.weight(.bold))
                        Text(suggestion.ownerName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: suggestion.actionType == .text ? "message.fill" : "phone.fill")
                        .foregroundStyle(.purple)
                        .font(.caption)
                }
                
                Text(suggestion.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button {
                    // Logic to open client and start communication
                    if let clientID = suggestion.clientID, let client = modelContext.model(for: clientID) as? Client {
                        openClient(client)
                    }
                } label: {
                    Text(NSLocalizedString("dashboard.reengage", value: "Re-engage", comment: ""))
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
            }
            .frame(width: 200)
        }
    }

    private func checklistSection(_ vm: DashboardViewModel) -> some View {
        Card(elevation: .regular) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("dashboard.getting_started", value: "Getting Started", comment: ""))
                            .font(.headline)
                        Text(String(format: NSLocalizedString("dashboard.steps_completed_fmt", value: "%d of %d steps completed", comment: ""), vm.checklist.filter({ $0.isCompleted }).count, vm.checklist.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation {
                            appSettings.isChecklistDismissed = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    // Closing it in the practice salon would retire the real one.
                    .disabled(isPracticeSalon)
                    .opacity(isPracticeSalon ? 0 : 1)
                    .accessibilityHidden(isPracticeSalon)
                }
                
                ProgressView(value: Double(vm.checklist.filter({ $0.isCompleted }).count), total: Double(vm.checklist.count))
                    .tint(DS.ColorToken.success)
                
                VStack(spacing: 2) {
                    ForEach(vm.checklist) { item in
                        Button {
                            handleChecklistTap(item.action)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isCompleted ? DS.ColorToken.success : DS.ColorToken.border)
                                    .font(.title3)

                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                    .strikethrough(item.isCompleted)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(item.isCompleted
                            ? AppLocalization.localized("checklist.hint.review", value: "Opens this section to review")
                            : AppLocalization.localized("checklist.hint.complete", value: "Opens the screen to finish this step"))
                        .accessibilityIdentifier("dashboard.checklist.\(item.action.rawValue)")
                    }
                }

                // Sample → real business. Shown only while sample clients
                // (fixed UUIDs) exist, and it removes only them. The full
                // Start Fresh wipe stays in Settings behind its own warning.
                if vm.hasSampleData {
                    Divider().opacity(0.4)

                    Button {
                        confirmSampleDataRemoval()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(DS.ColorToken.primary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(AppLocalization.localized("checklist.start_fresh.title", value: "Done exploring the demo?"))
                                    .font(.subheadline.weight(.semibold))
                                Text(AppLocalization.localized("checklist.start_fresh.subtitle", value: "Remove the sample clients. Your own clients stay."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(AppLocalization.localized("checklist.start_fresh.hint", value: "Asks before removing the sample clients"))
                    .accessibilityIdentifier("dashboard.removeSampleData")
                }
            }
            .padding(DS.Spacing.md)
        }
    }

    private func confirmSampleDataRemoval() {
        do {
            let inventory = try DataReset.sampleDataInventory(in: modelContext)
            guard !inventory.isEmpty else {
                Task { await vm?.refresh() }
                return
            }
            sampleRemovalInventory = inventory
        } catch {
            vm?.appError = .database(error.localizedDescription)
        }
    }

    /// Deep-links a Getting Started row to the screen where the step is finished.
    private func handleChecklistTap(_ action: DashboardViewModel.ChecklistAction) {
        HapticManager.impact(.light)
        if let section = action.settingsSection {
            // Open the Business section directly.
            openSettings(section)
            return
        }
        switch action {
        case .addClient:
            showNewClient = true
        case .firstVisit:
            // Starting a visit happens from a client/pet in the Clients tab.
            selectSurface(.clients, resetPath: true)
        case .branding:
            break
        }
    }

    private func openSettings(_ section: SettingSection) {
        NotificationCenter.default.post(name: .selectNavigationItem, object: nil, userInfo: [
            NavigationSelectionKey.item.rawValue: NavigationItem.settings.rawValue,
            NavigationSelectionKey.resetPath.rawValue: true,
            NavigationSelectionKey.settingsSection.rawValue: section.rawValue
        ])
    }

    private func reengagementSection(_ vm: DashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !vm.smartSuggestions.isEmpty || !vm.overduePets.isEmpty {
                HStack {
                    Text(NSLocalizedString("dashboard.reengagement_suggestions", value: "Re-engagement Suggestions", comment: ""))
                        .font(.headline)
                    Spacer()
                    Chip(
                        String(
                            format: NSLocalizedString("dashboard.actionable_count_fmt", value: "%d Actionable", comment: ""),
                            max(vm.smartSuggestions.count, vm.overduePets.count)
                        ),
                        style: .tinted,
                        size: .sm,
                        tint: .orange
                    )
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if !vm.smartSuggestions.isEmpty {
                            ForEach(vm.smartSuggestions.prefix(3)) { suggestion in
                                suggestionCard(suggestion)
                            }
                        } else {
                            ForEach(vm.overduePets.prefix(3)) { pet in
                                reengagementCard(pet)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reengagementCard(_ pet: Pet) -> some View {
        Card(elevation: .regular) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    AvatarView(.pet(species: pet.species, gender: pet.gender, name: pet.name, imageData: pet.photoData), size: .sm)
                    VStack(alignment: .leading) {
                        PetGenderNameBadge(pet: pet, maxNameWidth: 150)
                        Text(pet.owner?.fullName ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text(pet.isOverdue ? NSLocalizedString("dashboard.overdue_for_visit", value: "Overdue for visit", comment: "") : NSLocalizedString("dashboard.due_soon", value: "Due soon", comment: ""))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())

                Text(reengagementMessage(for: pet))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if let sms = pet.owner?.smsURL {
                        Link(destination: sms) {
                            Label(NSLocalizedString("dashboard.message", comment: ""), systemImage: "message.fill")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if let owner = pet.owner {
                        Button {
                            openClient(owner)
                        } label: {
                            Label(NSLocalizedString("dashboard.view_owner", value: "View Owner", comment: ""), systemImage: "person.fill")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
            }
            .frame(width: 180)
        }
    }

    private func reengagementMessage(for pet: Pet) -> String {
        let lastVisit = (pet.visits ?? [])
            .filter(\.isCompleted)
            .sorted { $0.sortKeyDate > $1.sortKeyDate }
            .first

        if let status = pet.nextVisitStatus, let lastVisit {
            return String(
                format: NSLocalizedString(
                    "dashboard.reengagement.message_with_last_fmt",
                    value: "%@. Last visit %@.",
                    comment: ""
                ),
                status,
                lastVisit.sortKeyDate.formatted(date: .abbreviated, time: .omitted)
            )
        }

        if let status = pet.nextVisitStatus {
            return status
        }

        if let owner = pet.owner?.fullName, !owner.isEmpty {
            return String(
                format: NSLocalizedString(
                    "dashboard.reengagement.message_owner_fmt",
                    value: "Follow up with %@ to keep the next appointment on the books.",
                    comment: ""
                ),
                owner
            )
        }

        return NSLocalizedString(
            "dashboard.reengagement.message_default",
            value: "Follow up to keep the next appointment on the books.",
            comment: ""
        )
    }

    private func smartSummary(_ vm: DashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Calendar.current.component(.hour, from: .now) < 12 ? NSLocalizedString("dashboard.greeting.morning", value: "Good Morning", comment: "") : NSLocalizedString("dashboard.greeting.afternoon", value: "Good Afternoon", comment: ""))
                .font(.title2.weight(.bold))

            let summary = generateSummaryText(vm)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private func generateSummaryText(_ vm: DashboardViewModel) -> String {
        var parts: [String] = []

        if vm.kpi.inProgressCount > 0 {
            parts.append(String(format: NSLocalizedString("dashboard.summary.active_sessions_fmt", value: "%d active sessions in progress", comment: ""), vm.kpi.inProgressCount))
        }

        if let trend = vm.kpi.revenueTrend {
            let direction = trend >= 0 ? NSLocalizedString("dashboard.trend.up", value: "up", comment: "") : NSLocalizedString("dashboard.trend.down", value: "down", comment: "")
            let pct = Formatters.percentString(abs(trend), showSign: false) ?? ""
            parts.append(String(format: NSLocalizedString("dashboard.summary.revenue_trend_fmt", value: "revenue is %@ %@ from yesterday", comment: ""), direction, pct))
        }

        guard !parts.isEmpty else {
            return NSLocalizedString("dashboard.summary.no_activity_today", value: "No activity yet today.", comment: "")
        }

        return parts.joined(separator: ", ") + "."
    }

    private func kpiSection(_ vm: DashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("dashboard.today", comment: "")).font(.headline)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    inProgressKPICard(vm)
                    kpiCard(title: NSLocalizedString("dashboard.completed", comment: ""), value: "\(vm.kpi.completedToday)", symbol: "checkmark.circle")
                        .accessibilityIdentifier("dashboard.kpi.completedCount")
                }
                GridRow {
                    Button {
                        selectSurface(.insights, resetPath: true)
                    } label: {
                        kpiCard(title: NSLocalizedString("dashboard.revenue", comment: ""), value: vm.kpi.revenueTodayString, symbol: "dollarsign.circle", trend: vm.kpi.revenueTrend)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(NSLocalizedString("dashboard.revenue", comment: "")))
                    .accessibilityValue(Text(vm.kpi.revenueTodayString))
                    .accessibilityHint(Text(NSLocalizedString("dashboard.opens_insights", value: "Opens Insights", comment: "")))
                    .accessibilityIdentifier("dashboard.kpi.revenueInsights")
                    .accessibilityAddTraits(.isButton)
                    .gridCellColumns(2)
                }
            }
        }
    }

    @ViewBuilder
    private func inProgressKPICard(_ vm: DashboardViewModel) -> some View {
        let label = NSLocalizedString("dashboard.in_progress", comment: "")
        kpiCard(title: label, value: "\(vm.kpi.inProgressCount)", symbol: "hourglass")
            .accessibilityIdentifier("dashboard.kpi.inProgressCount")
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("dashboard.quick_actions", comment: "")).font(.headline)
            LazyVGrid(columns: quickActionColumns, spacing: 12) {
                actionCard(
                    title: NSLocalizedString("dashboard.new_client", comment: ""),
                    symbol: "person.crop.circle.badge.plus",
                    accessibilityIdentifier: "dashboard.quickAction.newClient"
                ) { showNewClient = true }
                actionCard(
                    title: NSLocalizedString("dashboard.check_out", comment: ""),
                    symbol: "stop.circle",
                    accessibilityIdentifier: "dashboard.quickAction.checkOut"
                ) {
                    // Present the active sessions so one can be completed via the
                    // full checkout flow, rather than just opening history.
                    presentQuickCheckout()
                }
            }
        }
    }

    private var quickActionColumns: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]
        #else
        if horizontalSizeClass == .compact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]
        #endif
    }

    private func presentQuickCheckout() {
        Task { @MainActor in
            await vm?.refresh()
            showQuickCheckOut = true
        }
    }

    private func activeSessionsSection(_ vm: DashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("dashboard.active_sessions", comment: "")).font(.headline)
            LazyVStack(spacing: 10) {
                ForEach(vm.activeVisits) { visit in
                    ActiveVisitRow(visit: visit)
                }
            }
        }
    }

    private func overduePetsSection(_ vm: DashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("dashboard.needs_attention", comment: "")).font(.headline)
            LazyVStack(spacing: 12) {
                if vm.overduePets.isEmpty {
                    walkthroughEmptyDashboardCard(
                        title: AppLocalization.localized("tour.dash.attention.empty.title", value: "All caught up"),
                        message: AppLocalization.localized("tour.dash.attention.empty.message", value: "Pets due for their next groom show up here, so the front desk can call and rebook them.")
                    )
                } else {
                    ForEach(vm.overduePets, id: \.uuid) { pet in
                        if let owner = pet.owner {
                            attentionPetCard(pet, owner: owner)
                        }
                    }
                }
            }
        }
    }

    private func attentionPetCard(_ pet: Pet, owner: Client) -> some View {
        Button {
            openClient(owner)
        } label: {
            Card(elevation: .regular, accent: .leading(.color(attentionTint(for: pet)), thickness: 4)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(
                            .pet(
                                species: pet.species,
                                gender: pet.gender,
                                name: pet.name,
                                imageData: pet.photoData,
                                thumbnailData: pet.thumbnailData
                            ),
                            size: .md
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                PetGenderNameBadge(pet: pet, maxNameWidth: 150)
                                Spacer(minLength: 8)
                                if let status = pet.nextVisitStatus {
                                    Chip(status, style: .tinted, size: .xs, tint: attentionTint(for: pet))
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }

                            Text(owner.fullName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            attentionReasons(for: pet, owner: owner)

                            if let lastVisit = lastCompletedVisit(for: pet) {
                                Text(
                                    String(
                                        format: NSLocalizedString("pet.last_visit_fmt", comment: ""),
                                        lastVisit.sortKeyDate.formatted(date: .abbreviated, time: .omitted)
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("dashboard.attention.open_client_a11y", value: "Open client details for %@", comment: ""),
                owner.fullName
            )
        )
    }

    private func attentionReasons(for pet: Pet, owner: Client) -> some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(attentionReasonLabels(for: pet, owner: owner), id: \.self) { label in
                Chip(label, style: .tinted, size: .xs, tint: attentionTint(for: pet))
            }
        }
    }

    private func attentionReasonLabels(for pet: Pet, owner: Client) -> [String] {
        var labels: [String] = []

        if pet.needsAttention {
            labels.append(NSLocalizedString("dashboard.attention.reason_overdue", value: "Due now", comment: ""))
        }

        if !pet.behaviorTags.isEmpty {
            labels.append(contentsOf: pet.behaviorTags.prefix(2))
        }

        if let health = pet.health?.trimmingCharacters(in: .whitespacesAndNewlines), !health.isEmpty {
            labels.append(NSLocalizedString("dashboard.attention.reason_health", value: "Health note", comment: ""))
        }

        if owner.smsURL == nil && owner.telURL == nil {
            labels.append(NSLocalizedString("dashboard.attention.reason_missing_contact", value: "Missing contact", comment: ""))
        }

        return labels.isEmpty
            ? [NSLocalizedString("dashboard.attention.reason_review", value: "Review", comment: "")]
            : Array(labels.prefix(3))
    }

    private func attentionTint(for pet: Pet) -> Color {
        if pet.needsAttention {
            return .orange
        }

        if let health = pet.health?.trimmingCharacters(in: .whitespacesAndNewlines), !health.isEmpty {
            return .red
        }

        return .blue
    }

    private func lastCompletedVisit(for pet: Pet) -> Visit? {
        (pet.visits ?? [])
            .filter(\.isCompleted)
            .sorted { $0.sortKeyDate > $1.sortKeyDate }
            .first
    }

    private func recentClientsSection(_ vm: DashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("dashboard.recent_clients", comment: "")).font(.headline)
                Spacer()
                Button(NSLocalizedString("dashboard.view_all", comment: "")) {
                    selectSurface(.clients, resetPath: true)
                }
                .font(.footnote)
            }
            LazyVStack(spacing: 10) {
                if vm.recentClients.isEmpty {
                    walkthroughEmptyDashboardCard(
                        title: AppLocalization.localized("tour.dash.recent.empty.title", value: "No recent clients yet"),
                        message: AppLocalization.localized("tour.dash.recent.empty.message", value: "Once you add clients, the ones with the most recent visits show here for a quick jump back to their profile.")
                    )
                } else {
                    ForEach(vm.recentClients.prefix(5)) { client in
                        Button {
                            openClient(client)
                        } label: {
                            ClientRow(client: client)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func walkthroughEmptyDashboardCard(title: String, message: String) -> some View {
        Card(elevation: .regular) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.headline)
                    .foregroundStyle(DS.ColorToken.primary)
                    .frame(width: 30, height: 30)
                    .background(DS.ColorToken.primary.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func revenueSection(_ vm: DashboardViewModel) -> some View {
        #if canImport(Charts)
        let selectedPoint = selectedRevenuePoint(in: vm)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("dashboard.revenue_7d", comment: "")).font(.headline)
                Spacer()
                if let selected = selectedPoint {
                    Text("\(selected.date.formatted(.dateTime.weekday(.abbreviated))): \(selected.amount.moneyString)")
                        .font(.subheadline.bold())
                        .foregroundStyle(DS.ColorToken.primary)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            Card {
                if vm.revenueSeries.isEmpty {
                    ContentUnavailableView(NSLocalizedString("dashboard.no_revenue_yet", comment: ""), systemImage: "chart.bar.xaxis", description: Text(NSLocalizedString("dashboard.no_revenue_desc", comment: "")))
                        .frame(height: 180)
                } else {
                    Chart {
                        ForEach(vm.revenueSeries) { point in
                            BarMark(
                                x: .value(NSLocalizedString("insights.chart.day", value: "Day", comment: ""), point.date, unit: .day),
                                y: .value(NSLocalizedString("insights.revenue", comment: ""), point.amountDouble)
                            )
                            .foregroundStyle(DS.ColorToken.primary.gradient)
                            .opacity(selectedPoint == nil || selectedPoint?.id == point.id ? 1 : 0.4)
                        }

                        if let selected = selectedPoint {
                            RuleMark(x: .value(NSLocalizedString("common.selected", comment: ""), selected.date, unit: .day))
                                .foregroundStyle(.gray.opacity(0.3))
                                .offset(y: -10)
                                .zIndex(-1)
                        }
                    }
                    .chartXSelection(value: $selectedRevenueDate)
                    .frame(height: 180)
                    .animation(.spring(), value: selectedRevenueDate)
                }
            }
        }
        #else
        EmptyView()
        #endif
    }

    private func selectedRevenuePoint(in vm: DashboardViewModel) -> DashboardViewModel.RevenuePoint? {
        guard let selectedRevenueDate else { return nil }
        let calendar = Calendar.current
        return vm.revenueSeries.first { calendar.isDate($0.date, inSameDayAs: selectedRevenueDate) }
    }

    private func kpiCard(title: String, value: String, symbol: String, trend: Double? = nil) -> some View {
        Card {
            HStack(alignment: .top) {
                IconCircle(systemImage: symbol, size: .md)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.footnote).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())

                        if let trend = trend {
                            HStack(spacing: 2) {
                                Image(systemName: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(Formatters.percentString(abs(trend), showSign: false) ?? "")
                            }
                            .font(.caption2.bold())
                            .foregroundStyle(trend >= 0 ? .green : .red)
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(trend != nil ? String(format: NSLocalizedString("dashboard.trend.accessibility_fmt", value: "Trend: %@ %@", comment: ""), trend! >= 0 ? NSLocalizedString("dashboard.trend.up_label", value: "Up", comment: "") : NSLocalizedString("dashboard.trend.down_label", value: "Down", comment: ""), Formatters.percentString(abs(trend!), showSign: false) ?? "") : "")
    }

    private func actionCard(title: String, symbol: String, accessibilityIdentifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionCardLabel(title: title, symbol: symbol)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
            .frame(maxWidth: .infinity)
    }

    private func actionCardLabel(title: String, symbol: String) -> some View {
        Card {
            VStack(spacing: 8) {
                IconCircle(systemImage: symbol, size: .lg)
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
        }
    }

    private func selectSurface(_ item: NavigationItem, resetPath: Bool = false) {
        NotificationCenter.default.post(name: .selectNavigationItem, object: nil, userInfo: [
            NavigationSelectionKey.item.rawValue: item.rawValue,
            NavigationSelectionKey.resetPath.rawValue: resetPath
        ])
    }

    private func openClient(_ client: Client) {
        NotificationCenter.default.post(name: .navigateToClient, object: nil, userInfo: [
            "uuid": client.uuid
        ])
    }
    
}

// MARK: - Skeleton Components

struct SkeletonRect: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.1))
            .overlay(
                GeometryReader { geo in
                    Color.white.opacity(0.3)
                        .mask(
                            Rectangle()
                                .fill(
                                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: geo.size.width * 0.5)
                                .offset(x: -geo.size.width * 0.5 + (geo.size.width * 1.5 * phase))
                        )
                }
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    @ViewBuilder
    func applyAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

/// Lists active sessions so the dashboard "Check-Out" tile can route a visit
/// into the full checkout flow instead of just opening history.
private struct QuickCheckOutSheet: View {
    let activeVisits: [Visit]
    let onSelect: (Visit) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if activeVisits.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("dashboard.checkout_picker.empty_title", value: "No Active Sessions", comment: ""),
                        systemImage: "clock.badge.xmark",
                        description: Text(NSLocalizedString("dashboard.checkout_picker.empty_detail", value: "Check a pet in first to start a session you can check out.", comment: ""))
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(activeVisits, id: \.uuid) { visit in
                                if let pet = visit.pet {
                                    Button {
                                        onSelect(visit)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AvatarView(.pet(species: pet.species, gender: pet.gender, name: pet.name, imageData: pet.photoData), size: .sm)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(pet.name).font(.headline)
                                                if let owner = pet.owner?.fullName, !owner.isEmpty {
                                                    Text(owner).font(.footnote).foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "stop.circle.fill").foregroundStyle(.green)
                                        }
                                        .padding(12)
                                        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("dashboard.checkoutPicker.row.\(pet.name)")
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("dashboard.checkout_picker.title", value: "Check Out", comment: ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", value: "Cancel", comment: "")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: activeVisits.isEmpty ? 240 : 320, idealHeight: 380)
        #endif
    }
}
