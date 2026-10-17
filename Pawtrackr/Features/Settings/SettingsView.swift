//
//  SettingsView.swift
//  Pawtrackr
//
//  Created by Gemini on 9/15/25.
//

import SwiftUI
import SwiftData
import OSLog
#if os(iOS)
import UserNotifications
import UIKit
#elseif os(macOS)
import AppKit
#endif

private func settingsLocalized(_ key: String, value: String) -> String {
    AppLocalization.localized(key, value: value)
}

enum SettingSection: String, CaseIterable, Identifiable {
    case business, preferences, loyalty, security, dataExport, help, about
    var id: String { rawValue }
    var localizationKey: String {
        switch self {
        case .business: return "settings.section.business"
        case .preferences: return "settings.section.preferences"
        case .loyalty: return "settings.section.loyalty"
        case .security: return "settings.section.security"
        case .dataExport: return "settings.section.export"
        case .help: return "settings.section.help"
        case .about: return "settings.section.about"
        }
    }

    var title: LocalizedStringKey {
        LocalizedStringKey(localizationKey)
    }

    var subtitle: String {
        switch self {
        case .business:
            return settingsLocalized("settings.section.business.subtitle", value: "Your salon name on receipts, exports, and the dashboard.")
        case .preferences:
            return settingsLocalized("settings.section.preferences.subtitle", value: "Choose how the app opens, looks, and responds.")
        case .loyalty:
            return settingsLocalized("settings.section.loyalty.subtitle", value: "Visits earn points automatically. Choose the rewards your salon offers.")
        case .security:
            return settingsLocalized("settings.section.security.subtitle", value: "Protect client records with PIN, biometric unlock, and automatic locking rules.")
        case .dataExport:
            return settingsLocalized("settings.section.export.subtitle", value: "Export operational data for reporting, backup review, or handoff outside Pawtrackr.")
        case .help:
            return settingsLocalized("settings.section.help.subtitle", value: "A quick guide to the controls and everyday work in Pawtrackr.")
        case .about:
            return settingsLocalized("settings.section.about.subtitle", value: "Version details, guided setup, and the protected fresh-start control.")
        }
    }
    
    var icon: String {
        switch self {
        case .business: return "building.2.fill"
        case .preferences: return "slider.horizontal.3"
        case .loyalty: return "star.circle.fill"
        case .security: return "lock.shield.fill"
        case .dataExport: return "square.and.arrow.up"
        case .help: return "questionmark.circle.fill"
        case .about: return "info.circle.fill"
        }
    }

    var iconTint: Color {
        switch self {
        case .business, .dataExport, .about: return DS.ColorToken.calmBlue
        case .preferences, .help: return DS.ColorToken.primary
        case .loyalty: return DS.ColorToken.warning
        case .security: return DS.ColorToken.success
        }
    }

    var walkthroughAnchorID: WalkthroughAnchorID? {
        switch self {
        case .business:
            return .setBusiness
        case .loyalty:
            return .setLoyalty
        case .security:
            return .setSecurity
        case .dataExport:
            return .setData
        case .about:
            return .setAbout
        case .preferences, .help:
            return nil
        }
    }

    static func walkthroughSection(for anchor: WalkthroughAnchorID?) -> SettingSection? {
        guard let anchor else { return nil }
        if anchor == .setStartFresh { return .about }
        // The loyalty preview card inside the section, not the whole section.
        if anchor == .loyaltySimulator { return .loyalty }
        return allCases.first { $0.walkthroughAnchorID == anchor }
    }
}

enum SettingsAdaptiveLayout {
    static let maxReadableContentWidth: CGFloat = 940
    static let compactNavigatorThreshold: CGFloat = 700
    /// The Mac section list beside the selected page.
    static let macSectionListWidth: CGFloat = 176

    static func usesCompactSettingsNavigator(availableWidth: CGFloat) -> Bool {
        availableWidth < compactNavigatorThreshold
    }

    static func detailHorizontalPadding(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < 520 {
            return 16
        }
        if availableWidth < 820 {
            return 20
        }
        return 30
    }

    static func detailVerticalPadding(for availableWidth: CGFloat) -> CGFloat {
        availableWidth < 520 ? 18 : 30
    }

    static func contentMaxWidth(for availableWidth: CGFloat) -> CGFloat {
        let usableWidth = max(0, availableWidth - detailHorizontalPadding(for: availableWidth) * 2)
        return min(maxReadableContentWidth, usableWidth)
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var appSettings
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    @Environment(NavigationRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: SettingSection? = .business
    
    // State needed for sub-views
    @State private var showChangePIN = false
    @State private var showWipeConfirm = false

    var body: some View {
        #if os(macOS)
        GeometryReader { proxy in
            if SettingsAdaptiveLayout.usesCompactSettingsNavigator(availableWidth: proxy.size.width) {
                compactMacSettings
            } else {
                regularMacSettings
            }
        }
        .onAppear {
            synchronizeWalkthroughSection(walkthrough?.currentStep?.anchor)
        }
        .onChange(of: walkthrough?.currentStep?.anchor) { _, anchor in
            synchronizeWalkthroughSection(anchor)
        }
        // A deep link (e.g. a Getting Started row) asked for one section.
        // `initial` catches a request made before this screen appeared.
        .onChange(of: router.requestedSettingsSection, initial: true) { _, section in
            guard let section else { return }
            if selection != section { selection = section }
            router.requestedSettingsSection = nil
        }
        #else
        // No inner NavigationStack — SettingsView already lives inside ContentView's
        // settings NavigationStack. Nesting one here made NavigationLink(value:)
        // resolve to the wrong stack, so rows went grey and never opened. The
        // value links + this navigationDestination register on the ambient stack
        // (router.settingsPath, a type-erased NavigationPath), and the tour drives
        // that same path to step into a section.
        List(SettingSection.allCases) { section in
            NavigationLink(value: section) {
                HStack(spacing: 10) {
                    Image(systemName: section.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(section.iconTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    Text(section.title).foregroundStyle(Color.primary)
                }
            }
            .accessibilityIdentifier("settings.section.\(section.rawValue)")
        }
        .navigationTitle(Text("settings.title"))
        .navigationDestination(for: SettingSection.self) { section in
            let detail = SettingsDetailView(section: section,
                                            showChangePIN: $showChangePIN,
                                            showWipeConfirm: $showWipeConfirm)
            // Re-host the guided-tour overlay ON the pushed Settings detail so the
            // `set*` spotlights (which live in SettingsDetailView) resolve on iPad:
            // the split-view detail-column overlay sits OUTSIDE this NavigationStack
            // and can't see pushed anchors. Compact (iPhone) keeps its single root
            // overlay, so this is a no-op there to avoid a double-dim.
            if horizontalSizeClass != .compact, let walkthrough {
                detail.walkthroughOverlay(walkthrough, scope: .detailContent)
            } else {
                detail
            }
        }
        .onAppear {
            synchronizeWalkthroughSection(walkthrough?.currentStep?.anchor)
        }
        .onChange(of: walkthrough?.currentStep?.anchor) { _, anchor in
            synchronizeWalkthroughSection(anchor)
        }
        #endif
    }

    private func synchronizeWalkthroughSection(_ anchor: WalkthroughAnchorID?) {
        guard walkthrough?.currentStep?.surface == .settings else { return }

        #if os(macOS)
        if let section = SettingSection.walkthroughSection(for: anchor), selection != section {
            selection = section
        }
        #else
        if anchor == .settings {
            if !router.settingsPath.isEmpty { router.settingsPath = NavigationPath() }
        } else if let section = SettingSection.walkthroughSection(for: anchor) {
            // Consecutive stops in one section (the loyalty ladder, then its
            // preview card) keep the pushed screen instead of re-pushing it.
            let path = NavigationPath([section])
            if router.settingsPath != path { router.settingsPath = path }
        }
        #endif
    }

    #if os(macOS)
    private var selectedSectionBinding: Binding<SettingSection> {
        Binding {
            selection ?? .business
        } set: { newValue in
            selection = newValue
        }
    }

    /// The section list beside the selected page. Not a NavigationSplitView:
    /// Settings already sits in the app's split view, and a nested one
    /// pushed every page right by the app sidebar's width a second time.
    private var regularMacSettings: some View {
        HStack(spacing: 0) {
            settingsSectionList
                .frame(width: SettingsAdaptiveLayout.macSectionListWidth)
            Divider()
            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("settings.title"))
    }

    private var compactMacSettings: some View {
        VStack(spacing: 0) {
            Picker(settingsLocalized("settings.title", value: "Settings"), selection: selectedSectionBinding) {
                ForEach(SettingSection.allCases) { section in
                    HStack(spacing: 10) {
                    Image(systemName: section.icon).foregroundStyle(Color.primary)
                    Text(section.title).foregroundStyle(Color.primary)
                }
                        .tag(section)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
            settingsDetail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsSectionList: some View {
        List(selection: $selection) {
            ForEach(SettingSection.allCases) { section in
                HStack(spacing: 10) {
                    Image(systemName: section.icon).foregroundStyle(Color.primary)
                    Text(section.title).foregroundStyle(Color.primary)
                }
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .tag(section)
                    .accessibilityIdentifier("settings.section.\(section.rawValue)")
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        if let selection {
            let detail = SettingsDetailView(section: selection,
                                            showChangePIN: $showChangePIN,
                                            showWipeConfirm: $showWipeConfirm)
            if let walkthrough {
                detail.walkthroughOverlay(walkthrough, scope: .detailContent)
            } else {
                detail
            }
        } else {
            ContentUnavailableView(LocalizedStringKey("settings.select_setting"), systemImage: "gear")
        }
    }
    #endif
}

private struct SettingsDetailView: View {
    let section: SettingSection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesCompactDataTarget: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && section == .dataExport
        #else
        false
        #endif
    }
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var appSettings
    @Environment(WalkthroughController.self) private var walkthrough: WalkthroughController?
    @Binding var showChangePIN: Bool
    @Binding var showWipeConfirm: Bool
    @State private var showWipeBlockedAlert = false
    @State private var storeRestoreClientCount: Int?
    @AppStorage(DataSafetyMonitor.suspectedDataLossKey) private var dataLossSuspected = false
    /// About section: what the sample-clients card shows.
    @State private var sampleStatus = SampleDataStatus()
    @State private var sampleRemovalInventory: SampleDataInventory?

    private static let walkthroughAnchors: Set<WalkthroughAnchorID> = [
        .setBusiness,
        .setLoyalty,
        .setSecurity,
        .setData,
        .setAbout,
        .setStartFresh,
        .loyaltySimulator
    ]
    
    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(section.title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .optionalWalkthroughTarget(usesCompactDataTarget ? .setData : nil)

                        Text(section.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, -12)

                        content
                            .optionalWalkthroughTarget(section == .about || usesCompactDataTarget ? nil : section.walkthroughAnchorID)
                    }
                    .frame(maxWidth: SettingsAdaptiveLayout.contentMaxWidth(for: proxy.size.width), alignment: .leading)
                    .padding(.horizontal, SettingsAdaptiveLayout.detailHorizontalPadding(for: proxy.size.width))
                    .padding(.vertical, SettingsAdaptiveLayout.detailVerticalPadding(for: proxy.size.width))
                    // One readable column, centered in wide windows.
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .onAppear {
                    scrollToWalkthroughAnchorIfNeeded(walkthrough?.currentStep?.anchor, proxy: scrollProxy)
                }
                .onChange(of: walkthrough?.currentStep?.anchor) { _, anchor in
                    scrollToWalkthroughAnchorIfNeeded(anchor, proxy: scrollProxy)
                }
            }
        }
        .sheet(isPresented: $showChangePIN) {
            ChangePINSheet(isPresented: $showChangePIN)
                .environment(appSettings)
        }
        .sheet(isPresented: Binding(
            get: { storeRestoreClientCount != nil },
            set: { if !$0 { storeRestoreClientCount = nil } }
        )) {
            StoreRestoreView(currentClientCount: storeRestoreClientCount ?? 0)
        }
        .alert(
            settingsLocalized("settings.wipe.title", value: "Wipe Everything & Start Fresh?"),
            isPresented: $showWipeConfirm
        ) {
            Button(settingsLocalized("common.cancel", value: "Cancel"), role: .cancel) {}
            Button(settingsLocalized("settings.wipe.confirm", value: "Erase Everything"), role: .destructive) {
                performWipe()
            }
        } message: {
            Text(settingsLocalized(
                "settings.wipe.message",
                value: "This permanently erases every client, pet, visit, payment, inventory item, and report on this device — including the demo data — and cannot be undone. Your business profile and service menu are kept."
            ))
        }
        .alert(
            SampleDataCopy.removeTitle,
            isPresented: Binding(
                get: { sampleRemovalInventory != nil },
                set: { if !$0 { sampleRemovalInventory = nil } }
            ),
            presenting: sampleRemovalInventory
        ) { _ in
            Button(settingsLocalized("common.cancel", value: "Cancel"), role: .cancel) {}
            Button(SampleDataCopy.removeConfirm, role: .destructive) {
                removeSampleClients()
            }
        } message: { inventory in
            Text(SampleDataCopy.removeMessage(for: inventory))
        }
        .task {
            refreshSampleStatus()
        }
        .alert(
            settingsLocalized("data_safety.wipe_blocked.title", value: "Start Fresh is locked"),
            isPresented: $showWipeBlockedAlert
        ) {
            Button(settingsLocalized("common.ok", value: "OK"), role: .cancel) {}
        } message: {
            Text(settingsLocalized(
                "data_safety.wipe_blocked.message",
                value: "Pawtrackr detected that client data may be missing after an update. Export or recover the data before using Start Fresh, because that action erases the current records on this device."
            ))
        }
    }

    private func scrollToWalkthroughAnchorIfNeeded(_ anchor: WalkthroughAnchorID?, proxy: ScrollViewProxy) {
        guard let anchor, Self.walkthroughAnchors.contains(anchor) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard walkthrough?.currentStep?.anchor == anchor else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
    }

    /// Erases operational data and re-arms the getting-started checklist. Runs on
    /// the main context; live lists react to the deletions and empty out.
    private func performWipe() {
        guard !dataLossSuspected else {
            showWipeBlockedAlert = true
            return
        }

        do {
            try DataReset.wipeOperationalData(in: modelContext)
            DataSafetyMonitor.clearAfterIntentionalWipe()
            appSettings.resetForFreshStart()
            #if os(iOS)
            HapticManager.notify(.success)
            #endif
        } catch {
            Logger.database.error("Start Fresh wipe failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshSampleStatus()
    }

    // MARK: Sample clients

    private func refreshSampleStatus() {
        guard section == .about else { return }
        do {
            let status = SampleDataStatus(inventory: try DataReset.sampleDataInventory(in: modelContext))
            if status != sampleStatus {
                sampleStatus = status
            }
        } catch {
            Logger.database.error("Sample client status check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func confirmSampleRemoval() {
        do {
            let inventory = try DataReset.sampleDataInventory(in: modelContext)
            if inventory.isEmpty {
                refreshSampleStatus()
            } else {
                sampleRemovalInventory = inventory
            }
        } catch {
            Logger.database.error("Sample client lookup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeSampleClients() {
        do {
            try DataReset.removeSampleData(in: modelContext)
            #if os(iOS)
            HapticManager.notify(.success)
            #endif
        } catch {
            Logger.database.error("Removing sample clients failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshSampleStatus()
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .business: BusinessSectionView(appSettings: appSettings)
        case .preferences: PreferencesSectionView(appSettings: appSettings)
        case .loyalty: LoyaltyManagementView()
        case .security: SecuritySectionView(appSettings: appSettings, showChangePIN: $showChangePIN)
        case .dataExport: DataExportSectionView(modelContext: modelContext) {
            storeRestoreClientCount = (try? modelContext.fetchCount(FetchDescriptor<Client>())) ?? 0
        }
        case .help: HelpSectionView()
        case .about: AboutSectionView(
            showWipeConfirm: $showWipeConfirm,
            tourProgress: appSettings.tourProgress,
            hasCompletedAcademy: appSettings.hasCompletedAcademy,
            tourRole: appSettings.onboardingRole,
            onLaunchTour: { $0.post() },
            dataLossSuspected: dataLossSuspected,
            sampleStatus: sampleStatus,
            onRemoveSamples: confirmSampleRemoval
        )
        }
    }
}

private struct DataExportSectionView: View {
    let modelContext: ModelContext
    let onRestoreBackup: () -> Void
    @State private var isExportingClients = false
    @State private var isExportingVisits = false
    @State private var isCreatingEncryptedBackup = false
    @State private var exportDocument: ExportDocument?
    @State private var encryptedBackupURL: URL?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                SettingsCardHeader(
                    title: settingsLocalized("settings.export.card_title", value: "Spreadsheets"),
                    detail: settingsLocalized("settings.export.card_detail", value: "CSV files open in Numbers, Excel or Google Sheets. They hold client details, so keep them somewhere safe.")
                )

                SettingsActionRow(
                    systemImage: "person.3.sequence.fill",
                    tint: DS.ColorToken.primary,
                    title: settingsLocalized("settings.export.clients_title", value: "Clients"),
                    detail: settingsLocalized("settings.export.clients_detail", value: "Name, phone, email, address, notes and last visit for every client.")
                ) {
                    Button {
                        runExport(kind: .clients)
                    } label: {
                        Label(settingsLocalized("settings.export.csv_button", value: "Export CSV"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(settingsLocalized("settings.export.clients_csv", value: "Export Clients (CSV)"))
                    .accessibilityIdentifier("settings.exportClients")
                    .disabled(isExportingClients || isExportingVisits)
                }

                Divider()

                SettingsActionRow(
                    systemImage: "calendar.badge.clock",
                    tint: DS.ColorToken.info,
                    title: settingsLocalized("settings.export.visits_title", value: "Visits"),
                    detail: settingsLocalized("settings.export.visits_detail", value: "Date, pet, client, total, payment, status and notes for every visit.")
                ) {
                    Button {
                        runExport(kind: .visits)
                    } label: {
                        Label(settingsLocalized("settings.export.csv_button", value: "Export CSV"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(settingsLocalized("settings.export.visits_csv", value: "Export Visits (CSV)"))
                    .accessibilityIdentifier("settings.exportVisits")
                    .disabled(isExportingClients || isExportingVisits)
                }

                // The raw-store snapshot can't be restored and its key never leaves
                // this device, so it isn't offered as a backup (see
                // SecureStoreSnapshotExporter.isUserFacingExportEnabled).
                if SecureStoreSnapshotExporter.isUserFacingExportEnabled {
                    Button {
                        Task { await createEncryptedBackup() }
                    } label: {
                        Label(settingsLocalized("settings.export.encrypted_backup", value: "Create Encrypted Local Backup"), systemImage: "lock.doc.fill")
                    }
                    .accessibilityIdentifier("settings.createEncryptedBackup")
                    .disabled(isExportingClients || isExportingVisits || isCreatingEncryptedBackup)
                }

                if isExportingClients || isExportingVisits || isCreatingEncryptedBackup {
                    ProgressView(settingsLocalized("settings.export.preparing", value: "Preparing export..."))
                }

                if let exportDocument {
                    ShareLink(
                        item: exportDocument,
                        preview: SharePreview(exportDocument.filename)
                    ) {
                        Label(
                            String(format: settingsLocalized("settings.export.share_fmt", value: "Share %@"), exportDocument.filename),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                if SecureStoreSnapshotExporter.isUserFacingExportEnabled, let encryptedBackupURL {
                    ShareLink(item: encryptedBackupURL) {
                        Label(
                            settingsLocalized("settings.export.share_encrypted_backup", value: "Share Encrypted Backup"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Text(settingsLocalized(
                        "settings.export.encrypted_backup_note",
                        value: "This package can only be opened on this device, and Pawtrackr can't restore from it yet."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CardView {
                SettingsActionRow(
                    systemImage: "clock.arrow.circlepath",
                    tint: DS.ColorToken.success,
                    title: settingsLocalized("settings.export.restore_title", value: "On-device backups"),
                    detail: settingsLocalized("settings.export.restore_detail", value: "Pawtrackr keeps backup copies of your clients on this device. Restore one if clients go missing after an update.")
                ) {
                    Button(action: onRestoreBackup) {
                        Label(settingsLocalized("settings.export.restore_button", value: "Restore…"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(settingsLocalized("settings.restore_backup", value: "Restore from On-Device Backup"))
                    .accessibilityIdentifier("settings.restoreBackup")
                }
            }
        }
    }

    enum ExportKind { case clients, visits }
    private func runExport(kind: ExportKind) {
        exportError = nil
        exportDocument = nil

        switch kind {
        case .clients:
            isExportingClients = true
        case .visits:
            isExportingVisits = true
        }

        // Off the main actor on a context of its own: a client's row walks
        // every pet and visit, which a large salon would feel on the UI.
        let container = modelContext.container
        Task { @MainActor in
            defer {
                isExportingClients = false
                isExportingVisits = false
            }
            do {
                switch kind {
                case .clients:
                    exportDocument = try await ExportService.shared.exportClientsToCSVAsync(container: container)
                case .visits:
                    exportDocument = try await ExportService.shared.exportVisitsToCSVAsync(container: container)
                }
            } catch {
                exportError = String(format: settingsLocalized("settings.export.failed_fmt", value: "Export failed: %@"), error.localizedDescription)
            }
        }
    }

    @MainActor
    private func createEncryptedBackup() async {
        guard SecureStoreSnapshotExporter.isUserFacingExportEnabled else { return }
        isCreatingEncryptedBackup = true
        exportError = nil
        encryptedBackupURL = nil
        defer { isCreatingEncryptedBackup = false }

        do {
            encryptedBackupURL = try await SecureStoreSnapshotExporter.shared.exportSnapshot()
        } catch {
            exportError = String(format: settingsLocalized("settings.export.failed_fmt", value: "Export failed: %@"), error.localizedDescription)
        }
    }
}

private struct HelpSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardView {
                Label(settingsLocalized("settings.help.navigation_title", value: "Find your way"), systemImage: "square.grid.2x2.fill")
                    .font(.headline)
                HelpTopicRow(icon: "square.grid.2x2.fill", title: settingsLocalized("settings.help.dashboard_title", value: "Dashboard"), detail: settingsLocalized("settings.help.dashboard_detail", value: "See today's visits, quick actions, and items that need attention."))
                HelpTopicRow(icon: "person.3.fill", title: settingsLocalized("settings.help.clients_title", value: "Clients & pets"), detail: settingsLocalized("settings.help.clients_detail", value: "Search or filter clients, open a profile for contacts and pet notes, and use the pet card for check-in, checkout, or history."))
                HelpTopicRow(icon: "chart.bar.fill", title: settingsLocalized("settings.help.insights_title", value: "Insights"), detail: settingsLocalized("settings.help.insights_detail", value: "Review visits, revenue, services, and payment trends. Choose a period before exporting a report."))
                HelpTopicRow(icon: "gear", title: settingsLocalized("settings.help.settings_title", value: "Settings"), detail: settingsLocalized("settings.help.settings_detail", value: "Change preferences and security, manage rewards, or open Data Export and Help."))
            }
            CardView {
                Label(settingsLocalized("settings.help.daily_title", value: "A visit from start to finish"), systemImage: "pawprint.fill")
                    .font(.headline)
                HelpTopicRow(icon: "play.fill", title: settingsLocalized("settings.help.checkin_title", value: "Check in"), detail: settingsLocalized("settings.help.checkin_detail", value: "Start a pet's visit from its client profile. Notes and care alerts stay with that pet."))
                HelpTopicRow(icon: "stop.fill", title: settingsLocalized("settings.help.checkout_title", value: "Check out"), detail: settingsLocalized("settings.help.checkout_detail", value: "Choose services, add notes or photos, then enter the amount and payment method. Review the final total before confirming."))
                HelpTopicRow(icon: "creditcard.fill", title: settingsLocalized("settings.help.payment_title", value: "Payment controls"), detail: settingsLocalized("settings.help.payment_detail", value: "Cash, debit, credit, and Zelle record how the visit was paid. Enter a reference when the selected method asks for one."))
                HelpTopicRow(icon: "sparkles", title: settingsLocalized("settings.help.loyalty_title", value: "Points & rewards"), detail: settingsLocalized("settings.help.loyalty_fixed_detail", value: "Each completed, settled visit earns 20 points. Choose a reward in Payment or keep the points. Credits lower the amount due. Select Spa Package and redeem VIP Spa to make the entered service amount free."))
            }
            CardView {
                Label(settingsLocalized("settings.help.data_title", value: "Your records"), systemImage: "internaldrive.fill")
                    .font(.headline)
                HelpTopicRow(
                    icon: "internaldrive.fill",
                    title: settingsLocalized("settings.help.local_storage_title", value: "Local Storage"),
                    detail: settingsLocalized(
                        "settings.help.local_storage_detail",
                        value: "Client records, visits, payments, and photos stay on this device. Protect the device and keep a separate copy of important exports."
                    )
                )
                HelpTopicRow(
                    icon: "square.and.arrow.up",
                    title: settingsLocalized("settings.help.exports_title", value: "CSV exports"),
                    detail: settingsLocalized(
                        "settings.help.exports_detail",
                        value: "Data Export creates readable client or visit CSV files for review or handoff. A CSV is not a restorable app backup."
                    )
                )
                HelpTopicRow(icon: "arrow.counterclockwise", title: settingsLocalized("settings.help.backups_title", value: "Backups & restore"), detail: settingsLocalized("settings.help.backups_detail", value: "Data Export also lets you inspect available on-device store backups and restore one when needed. A restore replaces the active store only after preserving the current files."))
                HelpTopicRow(icon: "lock.shield.fill", title: settingsLocalized("settings.help.security_title", value: "Security"), detail: settingsLocalized("settings.help.security_detail", value: "Use Settings › Security to manage the app PIN, biometric unlock, and automatic locking."))
            }
        }
    }
}

/// One action in a settings card: an icon, what it does, and its button,
/// which moves under the text when the row is too narrow for both.
private struct SettingsActionRow<Action: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    let action: Action

    init(systemImage: String, tint: Color, title: String, detail: String, @ViewBuilder action: () -> Action) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                icon
                text
                Spacer(minLength: 12)
                action
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    text
                }
                action
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpTopicRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(DS.ColorToken.primary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct BusinessSectionView: View {
    @Bindable var appSettings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                SettingsCardHeader(
                    title: settingsLocalized("settings.business.identity_title", value: "Salon Identity"),
                    detail: settingsLocalized("settings.business.identity_detail", value: "This name appears on receipts, exports, and the dashboard.")
                )

                SettingsLabeledField(
                    title: settingsLocalized("settings.business.name", value: "Business Name"),
                    systemImage: "building.2.fill"
                ) {
                    TextField(settingsLocalized("settings.business.name_placeholder", value: "My Pet Grooming"), text: $appSettings.businessName)
                        .textFieldStyle(.roundedBorder)
                        .textLengthLimit($appSettings.businessName, to: TextInputLimits.name)
                }
            }
        }
    }
}

private struct PreferencesSectionView: View {
    @Bindable var appSettings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                SettingsCardHeader(
                    title: settingsLocalized("settings.preferences.experience_title", value: "App Experience"),
                    detail: settingsLocalized("settings.preferences.experience_detail", value: "Choose how Pawtrackr opens and which language and appearance it follows.")
                )

                Picker(selection: $appSettings.appLanguageOverride) {
                    ForEach(AppLanguageOverride.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    Label(settingsLocalized("settings.preferences.language", value: "Language"), systemImage: "globe")
                }

                Picker(selection: $appSettings.preferredColorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                } label: {
                    Label(settingsLocalized("settings.preferences.appearance", value: "Appearance"), systemImage: "circle.lefthalf.filled")
                }

                Picker(selection: $appSettings.defaultLaunchTab) {
                    ForEach(NavigationItem.allCases) { item in
                        Label(item.label, systemImage: item.icon)
                            .tag(item.rawValue)
                    }
                } label: {
                    Label(settingsLocalized("settings.preferences.default_launch", value: "Default Launch Tab"), systemImage: "rectangle.stack.fill")
                }

                SettingsSmartStatusRow(
                    title: settingsLocalized("settings.preferences.launch_summary", value: "Startup"),
                    value: launchSummary,
                    systemImage: "sparkle.magnifyingglass",
                    tint: DS.ColorToken.primary
                )
            }

            CardView {
                SettingsCardHeader(
                    title: settingsLocalized("settings.preferences.branding_title", value: "Brand & Feedback"),
                    detail: settingsLocalized("settings.preferences.branding_detail", value: "Accent color updates the app live; haptics affects taps and confirmations on supported devices.")
                )

                ColorPicker(
                    selection: brandColorBinding,
                    supportsOpacity: false
                ) {
                    Label(settingsLocalized("settings.preferences.brand_color", value: "Brand Color"), systemImage: "paintpalette.fill")
                }

                HStack {
                    Label(settingsLocalized("settings.preferences.brand_color_hex", value: "Brand Color Hex"), systemImage: "number")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(appSettings.brandColorHex.uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.ColorToken.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.ColorToken.primary.opacity(0.12), in: Capsule())
                }

                Toggle(isOn: $appSettings.hapticsEnabled) {
                    Label(settingsLocalized("settings.preferences.haptics", value: "Haptic Feedback"), systemImage: "hand.tap.fill")
                }
                .onChange(of: appSettings.hapticsEnabled) { _, _ in
                    HapticManager.preferenceDidChange()
                }
                Text(settingsLocalized("settings.preferences.smart_haptics", value: "Feedback adapts to selections, rewards and saved actions. Rapid repeats are filtered. Supported hardware provides tactile feedback; other devices keep visual feedback."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    HapticManager.notify(.success)
                } label: {
                    Label(settingsLocalized("settings.preferences.try_haptics", value: "Try Feedback"), systemImage: "hand.tap")
                }
                .pressScaleStyle()
                .accessibilityLabel(settingsLocalized("settings.preferences.try_haptics", value: "Try Feedback"))
                .accessibilityIdentifier("settings.haptics.preview")
                .disabled(!appSettings.hapticsEnabled)
            }
        }
    }

    private var brandColorBinding: Binding<Color> {
        Binding {
            Color(hex: appSettings.brandColorHex) ?? DS.ColorToken.primary
        } set: { newColor in
            if let hex = newColor.settingsHexRGB {
                appSettings.brandColorHex = hex
            }
        }
    }

    private var launchSummary: String {
        let selected = NavigationItem(rawValue: appSettings.defaultLaunchTab) ?? .dashboard
        return String(
            format: settingsLocalized("settings.preferences.launch_summary_fmt", value: "Opens to %@"),
            selected.label
        )
    }

}

private struct SecuritySectionView: View {
    @Bindable var appSettings: AppSettings
    @Binding var showChangePIN: Bool
    @State private var showDisableLockConfirm = false
    /// True while we're routing the user to set a PIN before enabling the lock.
    @State private var pendingEnableLock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                SettingsCardHeader(
                    title: settingsLocalized("settings.security.protection_title", value: "Access Protection"),
                    detail: securitySummary
                )

                Toggle(isOn: lockEnabledBinding) {
                    Label(settingsLocalized("settings.security.enable_lock", value: "Enable App Lock"), systemImage: "lock.shield.fill")
                }
                .accessibilityIdentifier("settings.appLockToggle")
                .onChange(of: showChangePIN) { _, isPresented in
                    // Sheet dismissed after we routed here to set a first PIN: enable
                    // the lock only if a PIN was actually chosen.
                    guard !isPresented, pendingEnableLock else { return }
                    pendingEnableLock = false
                    if appSettings.isPINSet {
                        appSettings.isLockEnabled = true
                    }
                }

                Toggle(isOn: $appSettings.isBiometricLockEnabled) {
                    Label(settingsLocalized("settings.security.biometric_unlock", value: "Biometric Unlock"), systemImage: "faceid")
                }
                .accessibilityIdentifier("settings.biometricLockToggle")
                .disabled(!appSettings.isLockEnabled)

                SettingsSmartStatusRow(
                    title: settingsLocalized("settings.security.pin_status", value: "PIN Status"),
                    value: pinStatus,
                    systemImage: pinStatusIcon,
                    tint: protectionStatus.isProtected ? DS.ColorToken.success : DS.ColorToken.warning
                )

                switch protectionStatus {
                case .protected:
                    Button(settingsLocalized("settings.pin.change", value: "Change PIN")) { showChangePIN = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.changePIN")
                case .needsPIN:
                    // Lock is on in settings (e.g. restored from a device backup)
                    // but the PIN didn't come with it: the app opens unlocked.
                    Button(settingsLocalized("settings.pin.set", value: "Set PIN")) { showChangePIN = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.setPIN")
                case .off:
                    EmptyView()
                }
            }

            CardView {
                SettingsCardHeader(
                    title: settingsLocalized("settings.security.auto_lock_title", value: "Auto-Lock Rules"),
                    detail: settingsLocalized("settings.security.auto_lock_detail", value: "Use these controls for shared front-desk devices or grooming-room stations.")
                )

                Toggle(isOn: $appSettings.autoLockOnBackground) {
                    Label(settingsLocalized("settings.security.lock_on_background", value: "Lock When App Closes"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("settings.autoLockOnBackgroundToggle")
                .disabled(!appSettings.isLockEnabled)

                Toggle(isOn: $appSettings.autoLockAfterInactivity) {
                    Label(settingsLocalized("settings.security.lock_after_inactivity", value: "Lock After Inactivity"), systemImage: "timer")
                }
                .accessibilityIdentifier("settings.autoLockAfterInactivityToggle")
                .disabled(!appSettings.isLockEnabled)

                Stepper(value: $appSettings.idleLockMinutes, in: 1...60) {
                    HStack {
                        Label(settingsLocalized("settings.security.idle_minutes", value: "Idle Timeout"), systemImage: "hourglass")
                        Spacer()
                        Text(String(format: settingsLocalized("settings.security.idle_minutes_value_fmt", value: "%d min"), appSettings.idleLockMinutes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!appSettings.isLockEnabled || !appSettings.autoLockAfterInactivity)

                SettingsSmartStatusRow(
                    title: settingsLocalized("settings.security.lock_timing", value: "Lock Timing"),
                    value: autoLockSummary,
                    systemImage: "timer.circle.fill",
                    tint: protectionStatus.isProtected && appSettings.autoLockAfterInactivity ? DS.ColorToken.success : DS.ColorToken.info
                )
            }
        }
        .alert(
            settingsLocalized("settings.security.disable_lock_title", value: "Disable App Lock?"),
            isPresented: $showDisableLockConfirm
        ) {
            Button(settingsLocalized("common.cancel", value: "Cancel"), role: .cancel) {}
            Button(settingsLocalized("settings.security.disable_lock_confirm", value: "Disable"), role: .destructive) {
                appSettings.isLockEnabled = false
            }
        } message: {
            Text(settingsLocalized(
                "settings.security.disable_lock_message",
                value: "Pawtrackr will stop requiring your PIN when the app opens or returns to the foreground."
            ))
        }
    }

    private var protectionStatus: AppLockProtectionStatus {
        appSettings.lockProtectionStatus
    }

    private var securitySummary: String {
        switch protectionStatus {
        case .protected:
            return settingsLocalized("settings.security.enabled_detail", value: "Client records need your PIN when Pawtrackr opens and whenever the auto-lock rules below apply.")
        case .needsPIN:
            return settingsLocalized("settings.security.needs_pin_detail", value: "App Lock is on, but this device has no PIN, so Pawtrackr opens without one. Set a PIN to protect client records.")
        case .off:
            return settingsLocalized("settings.security.disabled_detail", value: "App lock is off. Turn it on before sharing this device with staff.")
        }
    }

    private var pinStatus: String {
        switch protectionStatus {
        case .protected(let biometric):
            return biometric
                ? settingsLocalized("settings.security.pin_biometric", value: "PIN set with biometric unlock enabled")
                : settingsLocalized("settings.security.pin_only", value: "PIN set")
        case .needsPIN:
            return settingsLocalized("settings.security.pin_missing", value: "No PIN on this device")
        case .off:
            return settingsLocalized("settings.security.pin_disabled", value: "Not required")
        }
    }

    private var pinStatusIcon: String {
        switch protectionStatus {
        case .protected: return "checkmark.shield.fill"
        case .needsPIN: return "exclamationmark.shield.fill"
        case .off: return "shield.slash.fill"
        }
    }

    private var autoLockSummary: String {
        switch protectionStatus {
        case .off:
            return settingsLocalized("settings.security.auto_lock_disabled", value: "Enable app lock to use automatic locking.")
        case .needsPIN:
            // Nothing locks without a PIN (PinLockGate), so don't describe
            // timing that never happens.
            return settingsLocalized("settings.security.auto_lock_needs_pin", value: "Set a PIN to use automatic locking.")
        case .protected:
            break
        }

        if appSettings.autoLockAfterInactivity {
            return String(
                format: settingsLocalized("settings.security.lock_after_inactivity_detail_fmt", value: "Locks after %d minutes without interaction."),
                appSettings.idleLockMinutes
            )
        }

        if appSettings.autoLockOnBackground {
            return settingsLocalized("settings.security.lock_on_close_only", value: "Locks when the app closes or moves to the background.")
        }

        // Both rules off: PinLockGate still locks on every launch, and there
        // is no manual lock control, so say when it actually locks.
        return settingsLocalized("settings.security.lock_on_launch_only", value: "Locks only when Pawtrackr starts.")
    }

    private var lockEnabledBinding: Binding<Bool> {
        Binding {
            appSettings.isLockEnabled
        } set: { isEnabled in
            if isEnabled {
                if !appSettings.isPINSet {
                    // No PIN on this device (passcode-free setup, or a device
                    // restore that brought the setting back but not the
                    // Keychain PIN). Make the user set one first.
                    pendingEnableLock = true
                    showChangePIN = true
                } else {
                    appSettings.isLockEnabled = true
                }
            } else {
                showDisableLockConfirm = true
            }
        }
    }
}

private struct SettingsCardHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSmartStatusRow: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsLabeledField<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the About section's sample-clients card needs to know.
struct SampleDataStatus: Equatable {
    var inventory = SampleDataInventory(clientNames: [], addedPetNames: [])
}

private struct AboutSectionView: View {
    @Binding var showWipeConfirm: Bool
    let tourProgress: WalkthroughProgress
    /// Finished the whole Academy once: shows the graduate badge.
    let hasCompletedAcademy: Bool
    let tourRole: OnboardingRole
    let onLaunchTour: (WalkthroughLaunchRequest) -> Void
    let dataLossSuspected: Bool
    let sampleStatus: SampleDataStatus
    let onRemoveSamples: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            appCard
            academyCard
            sampleClientsCard
            startFreshCard
        }
    }

    /// The app and the version running.
    private var appCard: some View {
        CardView {
            HStack(spacing: 14) {
                Image(systemName: "pawprint.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(DS.ColorToken.primary.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Pawtrackr")
                        .font(.headline)
                    Text(verbatim: "\(settingsLocalized("settings.about.version", value: "Version")) \(versionText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The Academy in one place: continue it, re-run it, or replay a chapter.
    private var academyCard: some View {
        CardView {
            academyActions
                // The Academy's last stop. Only this part, so the spotlight
                // and its bubble still fit on an iPhone screen.
                .walkthroughTarget(.setAbout)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(settingsLocalized("settings.tour.lessons", value: "Chapters"))
                    .font(.subheadline.weight(.semibold))
                Text(settingsLocalized("settings.tour.lessons_caption", value: "Replay any chapter on its own. A check mark means you finished it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 2) {
                ForEach(Array(tourRole.tourLessonOrder.enumerated()), id: \.element) { index, lesson in
                    tourLessonRow(lesson, number: index + 1)
                }
            }
        }
    }

    /// The Academy's name, where it runs, and Continue / Re-run.
    private var academyActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(settingsLocalized("settings.tour.title", value: "Pawtrackr Academy"))
                } icon: {
                    Image(systemName: "graduationcap.fill")
                        .foregroundStyle(DS.ColorToken.primary)
                }
                .font(.headline)
                Spacer(minLength: 8)
                if hasCompletedAcademy {
                    Label(settingsLocalized("settings.tour.graduate", value: "Graduate"), systemImage: "medal.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(DS.ColorToken.primary, in: Capsule())
                        .accessibilityIdentifier("settings.academyGraduate")
                }
            }

            Text(settingsLocalized(
                "settings.tour.caption",
                value: "The Academy runs in a practice salon with sample clients, so you can try everything. Your real clients are never changed."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                onLaunchTour(.continueTour)
            } label: {
                Label(continueTourTitle, systemImage: "play.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(DS.ColorToken.primary, in: Capsule())
            }
            .pressScaleStyle()
            .accessibilityLabel(continueTourTitle)
            .accessibilityIdentifier("settings.continueTour")

            if showsRerun {
                Button {
                    onLaunchTour(.startOver)
                } label: {
                    Label(settingsLocalized("settings.tour.rerun_academy", value: "Re-run Academy"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(DS.ColorToken.primary)
                        .background(DS.ColorToken.primary.opacity(0.12), in: Capsule())
                }
                .pressScaleStyle()
                .accessibilityLabel(settingsLocalized("settings.tour.rerun_academy", value: "Re-run Academy"))
                .accessibilityIdentifier("settings.rerunAcademy")
            }
        }
    }

    /// Re-run starts over from the first stop. It's offered once there is
    /// progress to start over from, and not after every chapter is done,
    /// when the main button already replays from the start.
    private var showsRerun: Bool {
        guard tourProgress.continuePosition(in: tourRole.tourLessonOrder) != nil else { return false }
        return hasCompletedAcademy || tourProgress != WalkthroughProgress()
    }

    /// "Continue Academy (Chapter 3 of 5)" from saved progress and the role's
    /// chapter order, or "Replay the Academy" once every chapter is done.
    private var continueTourTitle: String {
        let order = tourRole.tourLessonOrder
        guard let position = tourProgress.continuePosition(in: order) else {
            return settingsLocalized("settings.tour.replay", value: "Replay the Academy")
        }
        return String(
            format: settingsLocalized("settings.tour.continue_fmt", value: "Continue Academy (Chapter %1$d of %2$d)"),
            position.lesson,
            position.of
        )
    }

    private func tourLessonRow(_ lesson: WalkthroughLesson, number: Int) -> some View {
        let isDone = tourProgress.isComplete(lesson)
        return Button {
            onLaunchTour(.lesson(lesson))
        } label: {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(DS.ColorToken.primary)
                    .frame(width: 22, height: 22)
                    .background(DS.ColorToken.primary.opacity(0.12), in: Circle())
                Label {
                    Text(lesson.title)
                        .foregroundStyle(DS.ColorToken.textPrimary)
                } icon: {
                    Image(systemName: lesson.icon)
                        .foregroundStyle(academyLessonTint(lesson))
                }
                .font(.subheadline)
                Spacer(minLength: 8)
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.ColorToken.success)
                        .accessibilityLabel(settingsLocalized("settings.tour.lesson_done", value: "Finished"))
                }
                Image(systemName: "play.circle")
                    .foregroundStyle(DS.ColorToken.primary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(settingsLocalized("settings.tour.lesson_hint", value: "Replays this chapter."))
        .accessibilityIdentifier("settings.tourLesson.\(lesson.rawValue)")
    }

    /// Reuses the app's semantic accents to distinguish Academy chapter subjects.
    private func academyLessonTint(_ lesson: WalkthroughLesson) -> Color {
        switch lesson {
        case .dailyWorkflow: return DS.ColorToken.primary
        case .clientRecords: return DS.ColorToken.calmBlue
        case .clientProfiles: return DS.ColorToken.success
        case .checkoutAndMoney: return DS.ColorToken.warning
        case .businessInsights: return DS.ColorToken.calmBlue
        }
    }

    /// Only while sample clients are in the salon: removes them. Trying the
    /// app with sample clients is what the Academy's practice salon is for.
    @ViewBuilder
    private var sampleClientsCard: some View {
        if !sampleStatus.inventory.isEmpty {
            CardView {
                Label(SampleDataCopy.settingsTitle, systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                Text(SampleDataCopy.loadedCaption(for: sampleStatus.inventory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRemoveSamples) {
                    Label(SampleDataCopy.removeConfirm, systemImage: "person.2.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.removeSampleData")
            }
        }
    }

    /// Destructive "Start Fresh": erases EVERY client, pet, visit and
    /// payment on this device, including real records. To drop only the
    /// sample clients, use the card above.
    private var startFreshCard: some View {
        CardView {
            Label(settingsLocalized("settings.wipe.section_title", value: "Start Fresh"), systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            Text(settingsLocalized("settings.wipe.section_caption", value: "Erase every client, pet, visit, and payment, real or sample, on this device and begin with an empty workspace. Your business profile and service menu are kept."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if dataLossSuspected {
                Label(
                    settingsLocalized(
                        "data_safety.start_fresh_locked",
                        value: "Locked while Pawtrackr checks missing client data."
                    ),
                    systemImage: "lock.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.ColorToken.danger)
            }

            Button(role: .destructive) {
                showWipeConfirm = true
            } label: {
                Label(settingsLocalized("settings.wipe.button", value: "Wipe & Start Fresh"), systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(dataLossSuspected)
            .walkthroughTarget(.setStartFresh)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

private struct CardView<Content: View>: View {
    let content: Content
    @State private var isHovering = false
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(isHovering ? 0.18 : 0), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

private extension Color {
    var settingsHexRGB: String? {
        #if os(iOS)
        let platformColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #elseif os(macOS)
        guard let platformColor = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let red = platformColor.redComponent
        let green = platformColor.greenComponent
        let blue = platformColor.blueComponent
        #else
        return nil
        #endif

        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
