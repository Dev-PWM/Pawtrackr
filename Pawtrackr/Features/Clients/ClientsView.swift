//
//  ClientsView.swift
//  Pawtrackr
//
//

import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct ClientsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalEventBus.self) private var eventBus
    @Environment(NavigationRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    var namespace: Namespace.ID

    init(namespace: Namespace.ID) {
        self.namespace = namespace
        _viewModel = State(initialValue: nil)
    }

    @State private var viewModel: ClientsViewModel?
    @State private var showingNewClientSheet = false
    @State private var showNotifications = false
    @State private var inbox = NotificationInbox()
    @State private var clientToDelete: Client?
    @State private var isSearchPresented = false
    @State private var searchFocusRequest = 0
    /// The notifications list was opened on the Academy's bell stop, so
    /// closing it moves the tour on.
    @State private var walkthroughOpenedNotifications = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let viewModel {
                        filterChips(viewModel)

                        if viewModel.inProgressClients.isEmpty && viewModel.otherClients.isEmpty {
                            emptyState(viewModel)
                        } else {
                            clientSections(viewModel)
                        }
                    } else {
                        clientsSkeleton
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 80)
                .frame(maxWidth: clientsContentMaxWidth)
                .frame(maxWidth: .infinity)
                .animation(MotionSystem.resolved(MotionSystem.fluid, reduceMotion: reduceMotion), value: viewModel?.inProgressClients.count)
                .animation(MotionSystem.resolved(MotionSystem.fluid, reduceMotion: reduceMotion), value: viewModel?.otherClients.count)
            }
            .clientsSearchable(
                text: searchTextBinding,
                isPresented: $isSearchPresented,
                prompt: NSLocalizedString("clients.search_placeholder", comment: "")
            )
            .background(DS.ColorToken.background)
            .alert(item: errorBinding) { error in
                Alert(
                    title: Text(NSLocalizedString("common.error", comment: "")),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "")))
                )
            }
            .alert(
                clientToDeleteTitle,
                isPresented: clientToDeletePresented,
                presenting: clientToDelete,
                actions: clientDeleteActions,
                message: clientDeleteMessage
            )
            .fabOverlay(padding: EdgeInsets(top: 0, leading: 0, bottom: 88, trailing: 24)) {
                #if os(iOS)
                FAB(systemImage: "person.fill.badge.plus", accessibilityLabel: NSLocalizedString("clients.add_client", comment: "")) {
                    showingNewClientSheet = true
                }
                .accessibilityIdentifier("clients.fab.addClient")
                #else
                EmptyView()
                #endif
            }
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewClientSheet = true
                    } label: {
                        Label(NSLocalizedString("clients.add_client", comment: ""), systemImage: "person.fill.badge.plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("clients.toolbar.addClient")
                }
                #endif

                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    MacToolbarSearchField(
                        text: searchTextBinding,
                        prompt: NSLocalizedString("clients.search_placeholder", comment: ""),
                        focusRequest: searchFocusRequest
                    )
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 380)
                }
                #endif

                // Sorting lives only in the list's "Sort:" menu, next to the
                // names it orders. A second copy up here duplicated it.
                ToolbarItem(placement: toolbarTrailingPlacement) {
                    notificationsToolbarButton
                }
            }
            .refreshable {
                viewModel?.fetchClients()
                await viewModel?.waitForPendingFetch()
            }
            .navigationTitle(NSLocalizedString("clients.title", value: "Client Center", comment: ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // No toolbar Refresh: the list reloads when it appears and when
            // clients or visits change.
            .sheet(isPresented: $showingNewClientSheet) {
            } content: {
                NewClientSheet(modelContext: modelContext)
            }
            .sheet(isPresented: $showNotifications) {
                NotificationSheetView(inbox: inbox, container: modelContext.container)
            }
            .onAppear {
                if viewModel == nil {
                    viewModel = ClientsViewModel(modelContext: modelContext, eventBus: eventBus)
                }
                viewModel?.fetchClients()
                inbox.refresh(container: modelContext.container)
                consumePendingSearchFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusClientSearch)) { _ in
                focusSearch()
            }
            .onChange(of: viewModel?.searchText) { _, newValue in
                guard !(newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      walkthrough?.currentStep?.advancesOn == .clientSearched
                else { return }
                // Let the list narrow for a moment, then move on and show
                // everyone again for the stops that follow.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1100))
                    if walkthrough?.observe(.clientSearched) == true {
                        viewModel?.searchText = ""
                    }
                }
            }
            .onChange(of: showNotifications) { _, isShowing in
                if isShowing {
                    walkthroughOpenedNotifications = walkthrough?.currentStep?.advancesOn == .notificationsClosed
                } else if walkthroughOpenedNotifications {
                    walkthroughOpenedNotifications = false
                    walkthrough?.observe(.notificationsClosed)
                }
            }
            .onChange(of: viewModel?.sortOption) { oldValue, newValue in
                guard oldValue != nil, oldValue != newValue else { return }
                HapticManager.selectionChanged()
                guard walkthrough?.currentStep?.advancesOn == .clientSortChanged else { return }
                // Leave the re-sorted list on screen for a moment, so the
                // names visibly flip before the next stop.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    walkthrough?.observe(.clientSortChanged)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clientDidCreate)) { _ in
                inbox.refresh(container: modelContext.container)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clientDidUpdate)) { _ in
                inbox.refresh(container: modelContext.container)
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxDidUpdate)) { _ in
                inbox.refresh(container: modelContext.container)
            }
            .onReceive(NotificationCenter.default.publisher(for: .visitDidComplete)) { note in
                guard let id = note.visitID else { return }
                Task {
                    await inbox.recordVisit(id: id, container: modelContext.container)
                }
            }
        }
    }

    private var toolbarTrailingPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .navigationBarTrailing
        #endif
    }

    private var clientsContentMaxWidth: CGFloat {
        #if os(macOS)
        return 1180
        #else
        return horizontalSizeClass == .compact ? 640 : 1100
        #endif
    }

    private var clientGridColumns: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)]
        #else
        if horizontalSizeClass == .compact {
            return [GridItem(.adaptive(minimum: 300, maximum: .infinity), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 12)]
        #endif
    }

    @ViewBuilder
    private func filterChips(_ viewModel: ClientsViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClientsViewModel.Filter.allCases, id: \.self) { filter in
                    Button {
                        guard viewModel.selectedFilter != filter else { return }
                        HapticManager.selectionChanged()
                        withAnimation(.spring(duration: 0.3)) {
                            viewModel.selectedFilter = filter
                        }
                        reportFilterMission(viewModel)
                    } label: {
                        Text("\(filter.displayName) (\(viewModel.filterCounts[filter, default: 0]))")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.selectedFilter == filter ? DS.ColorToken.primary : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                            .foregroundStyle(viewModel.selectedFilter == filter ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // The tour spotlights the pills themselves, not the full-width
            // scroll strip around them.
            .walkthroughAnchor(.clientFilters)
            .padding(.horizontal)
        }
    }

    /// The Academy's filter mission: the user picked a pill. The filtered
    /// list shows for a moment, then the tour moves on with All again, so
    /// the next stops have every client to point at.
    private func reportFilterMission(_ viewModel: ClientsViewModel) {
        guard walkthrough?.currentStep?.advancesOn == .clientFilterChanged else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            if walkthrough?.observe(.clientFilterChanged) == true {
                withAnimation(.spring(duration: 0.3)) {
                    viewModel.selectedFilter = .all
                }
            }
        }
    }

    /// The current order, named, next to the list it orders. It also explains
    /// why names read last-name-first. This is the screen's only sort
    /// control, and the guided tour's sort stop points here.
    private var inlineSortMenu: some View {
        Menu {
            Picker(selection: sortOptionBinding) {
                ForEach(ClientsViewModel.SortOption.allCases, id: \.self) { option in
                    Label(option.displayName, systemImage: sortIcon(for: option))
                        .tag(option)
                }
            } label: {
                Text(NSLocalizedString("clients.sort_by", value: "Sort By", comment: ""))
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                String(
                    format: AppLocalization.localized("clients.sort.inline_fmt", value: "Sort: %@"),
                    (viewModel?.sortOption ?? .lastName).displayName
                ),
                systemImage: "arrow.up.arrow.down"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .accessibilityIdentifier("clients.sortMenu.inline")
        .walkthroughTarget(.clientSort)
    }

    private func sortIcon(for option: ClientsViewModel.SortOption) -> String {
        switch option {
        case .lastName: return "textformat.abc"
        case .firstName: return "textformat"
        case .petName: return "pawprint"
        case .lastVisit: return "clock"
        case .newest: return "calendar.badge.plus"
        }
    }

    private var sortOptionBinding: Binding<ClientsViewModel.SortOption> {
        Binding(
            get: { viewModel?.sortOption ?? .lastName },
            set: { viewModel?.sortOption = $0 }
        )
    }

    @ViewBuilder
    private func clientSections(_ viewModel: ClientsViewModel) -> some View {
        // The tour's client-list stop points at the first card on screen.
        let hasInProgress = !viewModel.inProgressClients.isEmpty
        if hasInProgress {
            sectionHeader(NSLocalizedString("clients.in_progress", comment: ""), count: viewModel.inProgressCount, topPadding: 0)
            clientList(for: viewModel.inProgressClients, isInProgress: true, anchorsFirstCard: true)
        }

        sectionHeader(NSLocalizedString("clients.all_clients", comment: ""), count: viewModel.otherClients.count, topPadding: 16, showsSort: true)
        VStack(spacing: 10) {
            clientList(for: viewModel.otherClients, isInProgress: false, enableInfiniteScroll: true, anchorsFirstCard: !hasInProgress)
            if viewModel.canLoadMore {
                Button(action: { viewModel.loadMore() }) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("common.load_more", comment: "Load More"))
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func clientList(
        for clients: [Client],
        isInProgress: Bool? = nil,
        enableInfiniteScroll: Bool = false,
        anchorsFirstCard: Bool = false
    ) -> some View {
        LazyVGrid(columns: clientGridColumns, spacing: 12) {
            // All rows come from saved records. Their persistent identifiers stay
            // stable across search/sort and do not fault 10,000 UUID properties.
            ForEach(clients, id: \.persistentModelID) { client in
                Button(action: {
                    router.navigateToClientFromCard(client)
                    walkthrough?.observe(.clientOpened)
                }) {
                    ClientCard(
                        client: client,
                        namespace: nil,
                        isInProgressOverride: isInProgress,
                        displaysLastNameFirst: viewModel?.sortOption == .lastName,
                        showsMissingDetails: viewModel?.selectedFilter == .missingInfo
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .clientListAnchor(isActive: anchorsFirstCard && client.uuid == clients.first?.uuid)
                .accessibilityIdentifier("clients.row.\(client.firstName) \(client.lastName)")
                .contextMenu {
                    Button {
                        router.navigateToClient(client)
                    } label: {
                        Label(NSLocalizedString("clients.action.view_details", value: "View Details", comment: ""), systemImage: "person.crop.circle")
                    }

                    if supportsMultipleWindows && entitlements.isPremium {
                        Button {
                            openClientWindow(client, mode: .detail)
                        } label: {
                            Label(
                                NSLocalizedString("client.action.open_client_window", value: "Open Client Window", comment: ""),
                                systemImage: "rectangle.on.rectangle"
                            )
                        }

                        Button {
                            openClientWindow(client, mode: .loyalty)
                        } label: {
                            Label(
                                NSLocalizedString("client.action.open_loyalty_window", value: "Open Loyalty Window", comment: ""),
                                systemImage: "star.circle"
                            )
                        }
                    }

                    #if canImport(UIKit)
                    if let phone = client.phone, let tel = PhoneUtils.telURLString(phone), let url = URL(string: tel) {
                        Button {
                            viewModel?.recordAttentionOutreach(for: client, method: "call")
                            UIApplication.shared.open(url)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(NSLocalizedString("clients.action.call", value: "Call", comment: ""), systemImage: "phone")
                        }
                    }
                    
                    if let phone = client.phone, let sms = PhoneUtils.smsURLString(phone), let url = URL(string: sms) {
                        Button {
                            viewModel?.recordAttentionOutreach(for: client, method: "message")
                            UIApplication.shared.open(url)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(NSLocalizedString("clients.action.message", value: "Message", comment: ""), systemImage: "message")
                        }
                    }

                    if let email = client.email, let url = URL(string: "mailto:\(email)") {
                        Button {
                            UIApplication.shared.open(url)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(NSLocalizedString("clients.action.email", value: "Email", comment: ""), systemImage: "envelope")
                        }
                    }
                    #endif

                    Divider()

                    Button(role: .destructive) {
                        clientToDelete = client
                    } label: {
                        Label(NSLocalizedString("common.delete", comment: ""), systemImage: "trash")
                    }
                }
                .onAppear {
                    guard enableInfiniteScroll,
                          let vm = viewModel,
                          vm.canLoadMore,
                          !vm.isLoadingMore,
                          clients.suffix(5).contains(where: { $0.uuid == client.uuid }) else { return }
                    vm.loadMore()
                }
            }
        }
        .id("\(viewModel?.sortOption.rawValue ?? "")_\(clients.count)")
        .padding(.horizontal)
    }

    private func emptyState(_ viewModel: ClientsViewModel) -> some View {
        let isSearching = !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var title = isSearching
            ? NSLocalizedString("clients.no_results_title", comment: "")
            : NSLocalizedString("clients.empty_title", comment: "")
        var description = isSearching
            ? String(format: NSLocalizedString("clients.no_results_desc_fmt", comment: ""), viewModel.searchText)
            : NSLocalizedString("clients.empty_desc", comment: "")
        var icon = isSearching ? "magnifyingglass" : "person.3.sequence.fill"

        if !isSearching {
            switch viewModel.selectedFilter {
            case .active:
                title = NSLocalizedString("clients.empty.active_title", value: "No Active Sessions", comment: "")
                description = NSLocalizedString("clients.empty.active_desc", value: "There are no pets currently checked in.", comment: "")
                icon = "hourglass.badge.plus"
            case .overdue:
                title = NSLocalizedString("clients.empty.overdue_title", value: "No Attention Needed", comment: "")
                description = NSLocalizedString("clients.empty.overdue_desc", value: "No client outreach is pending right now.", comment: "")
                icon = "checkmark.seal.fill"
            case .missingInfo:
                title = NSLocalizedString("clients.empty.missing_info_title", value: "Data looks great!", comment: "")
                description = NSLocalizedString("clients.empty.missing_info_desc", value: "Every client has a phone, an email and an emergency contact on file.", comment: "")
                icon = "vial.viewfinder"
            default:
                break
            }
        }

        return ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text(description)
        )
        .padding(40)
    }

    private func sectionHeader(_ title: String, count: Int, topPadding: CGFloat = 0, showsSort: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if showsSort {
                inlineSortMenu
            }
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(.thinMaterial, in: .capsule)
            }
        }
        .padding(.horizontal)
        .padding(.top, topPadding)
    }

    private var notificationsCount: Int { inbox.unreadCount }
    private var notificationBadgeText: String { "\(min(notificationsCount, 9))" }

    private var notificationsAccessibilityLabel: String {
        String.localizedStringWithFormat(
            NSLocalizedString("clients.notifications_unread_fmt", value: "Notifications, %d unread", comment: ""),
            notificationsCount
        )
    }

    private var notificationsToolbarButton: some View {
        Button {
            showNotifications = true
        } label: {
            Image(systemName: "bell.fill")
                .overlay(alignment: .topTrailing) {
                    if notificationsCount > 0 {
                        Text(notificationBadgeText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Color.red, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityIdentifier("clients.toolbar.notifications")
        .accessibilityLabel(notificationsAccessibilityLabel)
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel?.searchText ?? "" },
            set: { viewModel?.searchText = $0 }
        )
    }

    private func consumePendingSearchFocus() {
        guard UserDefaults.standard.string(forKey: AppMenuCommand.pendingClientSearchFocusKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: AppMenuCommand.pendingClientSearchFocusKey)
        focusSearch()
    }

    private func focusSearch() {
        UserDefaults.standard.removeObject(forKey: AppMenuCommand.pendingClientSearchFocusKey)
        isSearchPresented = true
        #if os(macOS)
        searchFocusRequest += 1
        #endif
    }

    private func openClientWindow(_ client: Client, mode: DetachedClientWindowMode) {
        guard supportsMultipleWindows, entitlements.isPremium else { return }
        openWindow(id: "client-window", value: DetachedClientWindowRoute(clientUUID: client.uuid, mode: mode))
    }

    private var errorBinding: Binding<AppError?> {
        Binding(
            get: { viewModel?.appError },
            set: { viewModel?.appError = $0 }
        )
    }

    private var clientToDeleteTitle: String {
        guard let client = clientToDelete else { return "" }
        return String(format: NSLocalizedString("clients.delete_confirm_title_fmt", comment: ""), client.fullName)
    }

    private var clientToDeletePresented: Binding<Bool> {
        Binding(
            get: { clientToDelete != nil },
            set: { if !$0 { clientToDelete = nil } }
        )
    }

    @ViewBuilder
    private func clientDeleteActions(_ client: Client) -> some View {
        Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
            viewModel?.deleteClient(client)
        }
        Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { }
    }

    private func clientDeleteMessage(_ client: Client) -> Text {
        Text(NSLocalizedString("clients.delete_confirm_message", comment: ""))
    }

    private var clientsSkeleton: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                Card(elevation: .regular) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(width: 160, height: 12)
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)).frame(width: 120, height: 10)
                        }
                        Spacer()
                    }
                }
                .redacted(reason: .placeholder)
                .padding(.horizontal)
            }
        }
    }

}

private extension View {
    /// Attaches tour geometry without replacing a card's persistent identity.
    func clientListAnchor(isActive: Bool) -> some View {
        background {
            if isActive { Color.clear.walkthroughAnchor(.clientList) }
        }
    }

    @ViewBuilder
    func clientsSearchable(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        prompt: String
    ) -> some View {
        #if os(macOS)
        self
        #else
        self.searchable(
            text: text,
            isPresented: isPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(prompt)
        )
        #endif
    }
}

#if os(macOS)
private struct MacToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setAccessibilityIdentifier("clients.search")
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = prompt
        if field.stringValue != text {
            field.stringValue = text
        }

        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest

        DispatchQueue.main.async {
            field.window?.makeKeyAndOrderFront(nil)
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
#endif

private struct QuickStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        Card(elevation: .flat, showBorder: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(color)
                    Spacer()
                }
                Text(value)
                    .font(.title.weight(.bold))
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
