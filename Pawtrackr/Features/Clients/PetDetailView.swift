//
//  PetDetailView.swift
//  Pawtrackr
//
//  Updated by Assistant on 8/28/25 to use a ViewModel.
//  - All business logic (check-in, state management) is now in the ViewModel.
//  - Uses standard button styles and reusable components for UI consistency.
//  - Dangerous `completeCheckout` logic has been removed.
//

import SwiftUI
import SwiftData
import OSLog

private final class PDVMObserverToken {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

// MARK: - ViewModel
@Observable
@MainActor
final class PetDetailViewModel {
    var pet: Pet
    var appError: AppError? = nil
    private let modelContext: ModelContext
    private let visitRepository: VisitRepositoryProtocol
    private var visitCompleteObserver: PDVMObserverToken?
    @ObservationIgnored private let observationLifetime = EventObservationLifetime()
    @ObservationIgnored private var presentationContext: ModelContext?

    // State
    var sheetDestination: SheetDestination?

    // Bumped after writes so views observing `activeVisit` re-render even when
    // SwiftData's inverse-relationship update on `pet.visits` doesn't trigger
    // the parent @Observable's invalidation chain.
    var refreshNonce: Int = 0

    /// Open visit ID derived from a fresh store query rather than the in-memory
    /// `pet.visits` relationship — which stays stale after the cross-context
    /// `CheckoutTransactionActor` commit (see ClientDetailViewModel for details).
    private(set) var activeVisitID: PersistentIdentifier?
    private(set) var isCheckingIn = false

    // Computed Data
    var activeVisit: Visit? {
        _ = refreshNonce
        guard let id = activeVisitID else { return nil }
        guard isVisitStillOpenInStore(visitID: id) else {
            activeVisitID = nil
            refreshNonce &+= 1
            return nil
        }
        return modelContext.model(for: id) as? Visit
    }
    
    var sortedVisits: [Visit] {
        (pet.visits ?? []).sorted { $0.sortKeyDate > $1.sortKeyDate }
    }

    // MARK: - Stats
    var completedVisits: [Visit] {
        (pet.visits ?? []).filter { $0.isCompleted }
            .sorted { $0.sortKeyDate > $1.sortKeyDate }
    }
    
    var totalVisits: Int { (pet.visits ?? []).count }
    
    var totalSpent: Decimal {
        completedVisits.reduce(0) { $0 + $1.effectiveTotal }
    }
    
    var totalSpentString: String {
        totalSpent.moneyString
    }
    
    var averageDurationString: String {
        guard !completedVisits.isEmpty else { return "–" }
        let totalSeconds = completedVisits.map { Int($0.duration ?? 0) }.reduce(0, +)
        let avg = max(0, totalSeconds / completedVisits.count)
        return VisitTimer.format(seconds: avg)
    }
    
    init(pet: Pet, modelContext: ModelContext, eventBus: GlobalEventBus = GlobalEventBus()) {
        self.pet = pet
        self.modelContext = modelContext
        self.visitRepository = VisitRepository(modelContext: modelContext, eventBus: eventBus)

        let token = NotificationCenter.default.addObserver(
            forName: .visitDidComplete, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let completedPetID = note.petID, completedPetID != self.pet.persistentModelID { return }
                self.refreshCommittedPresentation()
            }
        }
        self.visitCompleteObserver = PDVMObserverToken(token)
        let stream = eventBus.stream
        observationLifetime.task = Task { [weak self] in
            for await event in stream {
                switch event {
                case .storeCommitted, .refreshRequired:
                    self?.refreshCommittedPresentation()
                default:
                    break
                }
            }
        }
        refreshActiveVisit()
    }

    /// Replaces committed presentation state while preserving a live editor's changes.
    private func refreshCommittedPresentation() {
        if !(pet.modelContext ?? modelContext).hasChanges {
            let reader = ModelContext(modelContext.container)
            let uuid = pet.uuid
            do {
                if let fresh = try reader.fetch(FetchDescriptor<Pet>(predicate: #Predicate { $0.uuid == uuid })).first {
                    presentationContext = reader
                    pet = fresh
                }
            } catch {
                appError = .database(error.localizedDescription)
                Logger.database.error("Pet presentation refresh failed: \(error.localizedDescription)")
            }
        }
        refreshActiveVisit()
        refreshNonce &+= 1
    }

    /// Re-derive the open visit for this pet from the store. Filters at the
    /// SQLite layer (`endedAt == nil`), so a just-checked-out visit is excluded
    /// even when the materialized relationship hasn't merged the actor's write.
    func refreshActiveVisit() {
        let petID = pet.persistentModelID
        let freshContext = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.endedAt == nil })
        let open = (try? freshContext.fetch(descriptor)) ?? []
        activeVisitID = open.first { $0.pet?.persistentModelID == petID }?.persistentModelID
    }

    private func isVisitStillOpenInStore(visitID: PersistentIdentifier) -> Bool {
        let petID = pet.persistentModelID
        let freshContext = ModelContext(modelContext.container)
        guard let visit = freshContext.model(for: visitID) as? Visit else { return false }
        return visit.endedAt == nil && visit.pet?.persistentModelID == petID
    }

    // MARK: Intents
    func checkIn() {
        guard pet.archivedAt == nil, activeVisit == nil, !isCheckingIn else {
            Logger.petDetail.info("checkIn skipped: pet \(self.pet.uuid) already has active visit")
            return
        }
        Logger.petDetail.info("checkIn start: pet \(self.pet.uuid)")
        isCheckingIn = true
        Task {
            defer { isCheckingIn = false }
            do {
                HapticManager.prepare(.success)
                let visit = try await visitRepository.checkIn(pet: pet, date: .now)
                HapticManager.notify(.success)
                refreshActiveVisit()
                refreshNonce &+= 1
                Logger.petDetail.info("checkIn saved visit \(visit.uuid); pet.activeVisit=\(self.pet.activeVisit?.uuid.uuidString ?? "nil")")
            } catch {
                appError = .database("Could not start a visit. Please try again.")
                Logger.petDetail.error("checkIn failed: \(String(describing: error))")
                HapticManager.notify(.error)
            }
        }
    }
    
    func showCheckout() {
        guard let petForCheckout = pet.modelContext != nil ? pet : nil else { return }
        guard let activeVisit else {
            refreshActiveVisit()
            return
        }
        sheetDestination = .checkout(petForCheckout, activeVisit)
    }
    
    func showHistory() {
        sheetDestination = .history(pet)
    }
    
    enum SheetDestination: Identifiable {
        case checkout(Pet, Visit)
        case history(Pet)
        
        var id: String {
            switch self {
            case .checkout(let pet, let visit): "checkout-\(pet.id)-\(visit.id)"
            case .history(let pet): "history-\(pet.id)"
            }
        }
    }

}

// MARK: - View
struct PetDetailView: View {
    @Environment(\.dismiss) private var dismiss
    /// Practice pets are never offered to Handoff or Siri.
    @Environment(\.isPracticeSalon) private var isPracticeSalon
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalEventBus.self) private var eventBus
    @State private var editingPet: Pet?
    @State private var viewModel: PetDetailViewModel?
    private let initialPet: Pet
    var namespace: Namespace.ID

    init(pet: Pet, namespace: Namespace.ID) {
        self.initialPet = pet
        self.namespace = namespace
        _viewModel = State(initialValue: nil)
    }
    
    var body: some View {
        Group {
            if let vm = viewModel {
                @Bindable var bvm = vm
                ScrollView {
                    VStack(spacing: 12) {
                        header(vm)
                        PetMilestoneView(pet: vm.pet)
                        actionRow(vm)
                        quickStats(vm)
                        transformationGallery(vm)
                        insightsSection(vm)
                        visitsSection(vm)
                    }
                    .padding(.vertical, 8)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { editingPet = vm.pet } label: { Image(systemName: "pencil") }
                            .pressScaleStyle()
                            .accessibilityLabel(AppLocalization.localized("pet.editor.title", value: "Edit Pet"))
                    }
                }
                .sheet(item: $editingPet) { pet in EditPetSheet(pet: pet) }
                .navigationTitle(vm.pet.name)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .userActivity("com.pawtrackr.viewPet", isActive: !isPracticeSalon) { activity in
                    activity.title = String(
                        format: AppLocalization.localized("handoff.viewing_fmt", value: "Viewing %@"),
                        vm.pet.name
                    )
                    activity.userInfo = ["petID": vm.pet.uuid.uuidString]
                    activity.isEligibleForHandoff = true
                }
                .sheet(item: $bvm.sheetDestination) { destination in
                    switch destination {
                    case .checkout(let petForCheckout, let activeVisit):
                        NavigationStack {
                            CheckoutView(pet: petForCheckout, visit: activeVisit)
                                .onDisappear {
                                    vm.refreshActiveVisit()
                                    vm.refreshNonce &+= 1
                                }
                        }
                    case .history(let petForHistory):
                        NavigationStack {
                            PetHistoryView(pet: petForHistory, wrapsInNavigationStack: false)
                        }
                    }
                }
                // Presented from the main content (not the nested action row) so the
                // template picker reliably opens on macOS as well as iOS/iPadOS.
                .sheet(isPresented: $showCommunication) {
                    CommunicationSheet(pet: vm.pet, visit: vm.activeVisit)
                }
                // Use the modern `.alert(_:isPresented:presenting:actions:message:)`
                // API instead of the deprecated `.alert(item:)`. Two deprecated
                // `.alert` modifiers on the same view (along with the check-in
                // confirm alert above) caused the second to silently win, so the
                // "already in session" notice never appeared — the user saw a
                // blue tile that responded to nothing.
                .alert(
                    Text(AppLocalization.localized("common.error")),
                    isPresented: Binding(
                        get: { bvm.appError != nil },
                        set: { if !$0 { bvm.appError = nil } }
                    ),
                    presenting: bvm.appError
                ) { _ in
                    Button(AppLocalization.localized("common.ok"), role: .cancel) {}
                } message: { error in
                    Text(error.localizedDescription)
                }
            } else {
                ProgressView()
                    .task { viewModel = PetDetailViewModel(pet: initialPet, modelContext: modelContext, eventBus: eventBus) }
            }
        }
    }

    @ViewBuilder
    private func transformationGallery(_ vm: PetDetailViewModel) -> some View {
        let history = vm.pet.transformationHistory

        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("pet.transformations", value: "Transformations")).font(.headline).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<history.count, id: \.self) { idx in
                            let item = history[idx]
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    photoBox(data: item.before, label: AppLocalization.localized("checkout.photo.before", value: "Before"))
                                    photoBox(data: item.after, label: AppLocalization.localized("checkout.photo.after", value: "After"))
                                }
                                Text(item.date, style: .date)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func photoBox(data: Data?, label: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let data, let image = ImageCache.shared.image(data: data, maxDimension: 300) {
                    #if canImport(UIKit)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                    #elseif canImport(AppKit)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                    #endif
                } else {
                    Color.gray.opacity(0.1)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(label)
                .font(.system(size: 10, weight: .black))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(6)
        }
    }
    
    private func header(_ vm: PetDetailViewModel) -> some View {
            Card(accent: .top(.color(DS.ColorToken.gender(vm.pet.gender)))) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        AvatarView(.pet(species: vm.pet.species, gender: vm.pet.gender, name: vm.pet.name, imageData: vm.pet.photoData), size: .lg)
                            .matchedGeometryEffect(id: "pet-avatar-\(vm.pet.id)", in: namespace)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(vm.pet.name).font(.title2.weight(.semibold))
                            Text(vm.pet.shortDescriptor).font(.subheadline).foregroundStyle(.secondary)
                            if let age = vm.pet.ageString { Text(String(format: AppLocalization.localized("pet.age_fmt"), age)).font(.footnote).foregroundStyle(.secondary) }
                            ownerInfo(vm)
                        }
                        Spacer()
                    }
                    if vm.pet.isAggressive { petAggressiveBanner(vm) }
                    if vm.pet.hasSpecialNeeds {
                        VStack(alignment: .leading, spacing: 8) {
                            SpecialNeedsPetBadge()
                            Text(AppLocalization.localized("checkout.safety_alert.special_needs", value: "Review care notes, comfort needs, and allow extra time."))
                                .font(.caption)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BehaviorTagIcons.tint(for: .specialNeeds).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("petDetail.specialNeedsBanner")
                    }
                    if vm.activeVisit != nil { sessionStatus(vm) }
                }
            }
            .padding(.horizontal)
        }

    /// High-visibility safety flag shown beneath the pet's profile header when
    /// the pet is marked aggressive, so staff are warned before handling.
    private func petAggressiveBanner(_ vm: PetDetailViewModel) -> some View {
        let status = vm.pet.aggressionClearanceStatus
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                if status.isProbationary {
                    Text(String(
                        format: AppLocalization.localized("pet.safety_alert.probation_title_fmt", value: "Caution: Aggressive Behavior (%d/3 Visits Without Aggression)"),
                        status.calmStreak
                    ))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    Text(String(
                        format: AppLocalization.localized("pet.safety_alert.probation_message_fmt", value: "This pet is on behavior probation (%d more visit(s) without aggression needed to clear safety warning). Alert the team and handle with care."),
                        status.remainingVisits
                    ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        ForEach(0..<status.requiredStreak, id: \.self) { index in
                            Capsule()
                                .fill(index < status.calmStreak ? Color.green : Color.white.opacity(0.35))
                                .frame(height: 4)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text(AppLocalization.localized("pet.safety_alert.title", value: "Caution: Aggressive Behavior"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(AppLocalization.localized("pet.safety_alert.message", value: "This pet is flagged as aggressive. Alert the team and handle with care. (Requires 3 consecutive visits without aggression to clear)."))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.danger, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("petDetail.safetyBanner")
    }

    private func ownerInfo(_ vm: PetDetailViewModel) -> some View {
            Group {
                if let owner = vm.pet.owner {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalization.localized("pet.owner")).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill").foregroundStyle(.secondary)
                            Text(owner.fullName).font(.footnote.weight(.medium))
                            if let phone = owner.phone, !phone.isEmpty {
                                Spacer(minLength: 8)
                                Image(systemName: "phone.fill").foregroundStyle(.secondary)
                                Text(phone).font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }

    private func sessionStatus(_ vm: PetDetailViewModel) -> some View {
            HStack(spacing: 10) {
                Label(AppLocalization.localized("status.in_session"), systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.ColorToken.success)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(DS.ColorToken.success.opacity(0.12), in: Capsule())
                Spacer()
                // Drive the elapsed clock from the active visit's start date via a
                // self-updating TimelineView. The view model's `visitTimer` is a
                // Combine `ObservableObject` held as a plain `let` on an @Observable
                // VM, so SwiftUI never subscribes to its per-second ticks — the label
                // would render once and freeze at "0m". TimelineView ticks on its own,
                // matching the working pattern in ClientDetailView's status pill.
                if let started = vm.activeVisit?.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let secs = max(0, Int(Date().timeIntervalSince(started)))
                        Label(VisitTimer.format(seconds: secs), systemImage: "clock.arrow.circlepath")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .monospacedDigit()
                            .accessibilityLabel(VisitTimer.spelledOut(seconds: secs))
                    }
                }
            }
        }
        
    @State private var showCommunication = false

    private func actionRow(_ vm: PetDetailViewModel) -> some View {
            HStack(spacing: 12) {
                actionTile(title: AppLocalization.localized("client_detail.message", value: "Message"), systemImage: "message.fill", tint: .indigo) { showCommunication = true }
                actionTile(title: AppLocalization.localized("pet.view_history"), systemImage: "clock.arrow.circlepath", tint: .primary) { vm.showHistory() }
                actionTile(title: AppLocalization.localized("pet.check_in"), systemImage: "play.fill", tint: .blue, disabled: vm.activeVisit != nil || vm.isCheckingIn) {
                    if vm.activeVisit != nil {
                        vm.appError = .validation(.custom(message: String(
                            format: AppLocalization.localized("pet.already_in_session", value: "%@ is already in session."),
                            vm.pet.name
                        )))
                        HapticManager.notify(.warning)
                        return
                    }
                    vm.checkIn()
                }
                .opacity(vm.activeVisit == nil && !vm.isCheckingIn ? 1.0 : 0.55)
                actionTile(title: AppLocalization.localized("pet.check_out"), systemImage: "checkmark.seal.fill", tint: .green, disabled: vm.activeVisit == nil) { vm.showCheckout() }
            }
            .padding(.horizontal)
        }

    private func actionTile(title: String, systemImage: String, tint: Color, disabled: Bool = false, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(disabled ? 0.5 : 1)
            .disabled(disabled)
        }

    private func insightsSection(_ vm: PetDetailViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(AppLocalization.localized("insights.professional_insights")).font(.subheadline.weight(.bold))
                    Spacer()
                    Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.blue)
                }
                
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalization.localized("insights.engagement")).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("\(NSDecimalNumber(decimal: vm.pet.engagementScore * 100).intValue)%").font(.title3.weight(.bold))
                            EngagementIndicator(score: NSDecimalNumber(decimal: vm.pet.engagementScore).doubleValue)
                        }
                    }
                    
                    Divider().frame(height: 30)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalization.localized("insights.lifetime_value")).font(.caption).foregroundStyle(.secondary)
                        Text(vm.pet.lifetimeValue.moneyString).font(.title3.weight(.bold)).foregroundStyle(.green)
                    }
                    
                    Spacer()
                }
                
                if let firstVisit = vm.pet.firstVisitDate {
                    Text(String(format: AppLocalization.localized("insights.client_since_fmt"), firstVisit.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }

    private func quickStats(_ vm: PetDetailViewModel) -> some View {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.localized("pet.quick_stats")).font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        statTile(label: AppLocalization.localized("pet.total_visits"), value: "\(vm.totalVisits)", tint: .blue)
                        statTile(label: AppLocalization.localized("pet.total_spent"), value: vm.totalSpentString, tint: .green)
                        statTile(label: AppLocalization.localized("pet.avg_duration"), value: vm.averageDurationString, tint: .purple)
                    }
                }
            }
            .padding(.horizontal)
        }

    private func statTile(label: String, value: String, tint: Color) -> some View {
            VStack(spacing: 6) {
                Text(value)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        
    private func visitsSection(_ vm: PetDetailViewModel) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                // Section header
                HStack {
                    Text(AppLocalization.localized("pet.recent_visits")).font(.headline)
                    Spacer()
                    Text("\(vm.sortedVisits.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityLabel(String(format: AppLocalization.localized("pet.recent_visits_count_fmt", value: "Recent visits count %d"), vm.sortedVisits.count))
                }
                .padding(.horizontal)

                // Empty state
                if vm.sortedVisits.isEmpty {
                    ContentUnavailableView(AppLocalization.localized("pet.no_visits_yet"), systemImage: "calendar.badge.plus")
                } else {
                    VStack(spacing: 12) {
                        // Highlight current visit (if any)
                        if let current = vm.activeVisit {
                            currentVisitCard(current)
                                .padding(.horizontal)
                        }

                        // Remaining visits
                        ForEach(vm.sortedVisits.filter { $0.endedAt != nil }) { visit in
                            NavigationLink(destination: VisitDetailView(visit: visit)) {
                                VisitTimelineRow(visit: visit)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }
                }
            }
        }

    private func currentVisitCard(_ visit: Visit) -> some View {
            Card(showBorder: true) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(AppLocalization.localized("status.in_progress", value: "In Progress"), systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.ColorToken.success)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(DS.ColorToken.sessionBackground, in: Capsule())
                        Text(startedString(visit.startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(visit.totalCurrencyString)
                                .font(.subheadline.weight(.semibold))
                            // Live-ticking elapsed time, driven off the visit start
                            // date (see note in `sessionStatus`).
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let secs = max(0, Int(Date().timeIntervalSince(visit.startedAt)))
                                Text(VisitTimer.format(seconds: secs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Services
                    if !(visit.items ?? []).isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(visit.items ?? []) { item in
                                Chip(item.displayName, style: .tinted, size: .sm)
                            }
                        }
                    }

                    // Payment / media footer
                    HStack(spacing: 8) {
                        if let method = visit.payment?.method {
                            Label(method.displayName, systemImage: method.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(AppLocalization.localized("visit.payment_pending"), systemImage: "creditcard")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        mediaThumbs(visit)
                    }
                }
            }
            .leftAccentRail(DS.ColorToken.session)
        }

    private func mediaThumbs(_ visit: Visit) -> some View {
            HStack(spacing: 6) {
                if let data = visit.beforePhotoData {
                #if canImport(UIKit)
                    if let img = ImageCache.shared.image(data: data, maxDimension: 64) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.ColorToken.border, lineWidth: 0.5))
                    }
                #elseif canImport(AppKit)
                    if let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.ColorToken.border, lineWidth: 0.5))
                    }
                #endif
                }
                if let data = visit.afterPhotoData {
                #if canImport(UIKit)
                    if let img = ImageCache.shared.image(data: data, maxDimension: 64) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.ColorToken.border, lineWidth: 0.5))
                    }
                #elseif canImport(AppKit)
                    if let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.ColorToken.border, lineWidth: 0.5))
                    }
                #endif
                }
            }
        }

    private static let relativeDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func startedString(_ date: Date) -> String {
        "\(Self.relativeDayFormatter.string(from: date)), \(Self.timeOnlyFormatter.string(from: date))"
    }
}

struct EngagementIndicator: View {
    let score: Double

    var color: Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .orange }
        return .red
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 4)
                    .scaleEffect(1.2)
            )
    }
}

private extension Logger {
    static let petDetail = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "PetDetail")
}
