//
//  PracticeSalon.swift
//  Pawtrackr
//
//  The Academy's sandbox: an in-memory store filled with the sample clients
//  that the main window runs on while the guided tour is open. The user can
//  add clients, check pets in and walk a checkout without changing their
//  salon. It never touches the store on disk and is thrown away when the
//  tour ends, or when the app quits.
//
//  What could still reach the real salon, and how each is kept out:
//  - Spotlight: the practice store is registered with `SpotlightIndexer`
//    before seeding, so none of its records are indexed.
//  - UserDefaults: seeding records example prices in a suite of its own,
//    cleared on open and on close.
//  - Handoff and the Getting Started checklist: views check
//    `EnvironmentValues.isPracticeSalon` before advertising a client or
//    retiring the checklist.
//  - Checkout drafts: tour checkouts run in the walkthrough preview, which
//    never writes a draft.
//

import SwiftUI
import SwiftData
import OSLog

@Observable
@MainActor
final class PracticeSalon {
    struct Session {
        /// New for every salon opened, so the app rebuilds its screens
        /// when it moves between the real store and a practice one.
        let id = UUID()
        let container: ModelContainer
        let dataStore: DataStoreService
        /// Practice checkout state belongs to this session and never reaches disk.
        let checkoutDraftStore = CheckoutDraftStore(inMemory: true)
        let checkoutEventRecorder = CheckoutEventRecorder(persistsEvents: false)
    }

    /// The open practice salon, or nil while the app runs on the real one.
    private(set) var session: Session?

    var isOpen: Bool { session != nil }

    /// Where seeding records its example prices. Never `.standard`.
    static let defaultsSuiteName = "com.pawtrackr.practiceSalon"

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "PracticeSalon")

    /// Opens a fresh practice salon, or keeps the one already open. Returns
    /// false when the in-memory store couldn't be built: the tour then runs
    /// on the real salon in its explain-only form.
    @discardableResult
    func open() -> Bool {
        guard session == nil else { return true }
        do {
            session = try Self.makeSession()
            Self.log.info("Practice salon opened.")
            return true
        } catch {
            Self.log.error("Practice salon couldn't open: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Throws the practice salon away. The main window goes back to the
    /// real store.
    func close() {
        guard let session else { return }
        SpotlightIndexer.shared.endPracticeSalon(session.container)
        Self.clearPracticeDefaults()
        self.session = nil
        Self.log.info("Practice salon closed.")
    }

    private static func makeSession() throws -> Session {
        let schema = Schema(PawtrackrSchema.models)
        // A name of its own, so it can't collide with the store on disk.
        let configuration = ModelConfiguration(
            "PracticeSalon-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        SpotlightIndexer.shared.beginPracticeSalon(container)
        do {
            try seed(container.mainContext)
        } catch {
            SpotlightIndexer.shared.endPracticeSalon(container)
            throw error
        }
        return Session(container: container, dataStore: DataStoreService(container: container))
    }

    enum OpenError: Error {
        /// The practice defaults suite couldn't be made. Seeding would
        /// otherwise record its example prices in the app's own defaults.
        case noDefaultsSuite
    }

    /// The sample clients, their visits, the service menu and loyalty
    /// points, so every tour stop has something real to show.
    static func seed(_ context: ModelContext) throws {
        clearPracticeDefaults()
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else { throw OpenError.noDefaultsSuite }
        try DemoDataSeeder.seedIfNeeded(in: context, userDefaults: defaults)
        try addWaitingPet(in: context)
        DataMigrations.ensureLoyaltyDefaults(in: context)
        DataMigrations.backfillLoyaltyLedger(in: context)
        if context.hasChanges {
            try context.save()
        }
    }

    /// Ava's cat Pepper, just arrived and not checked in yet: the Academy's
    /// Check In mission needs a pet that is waiting, while Milo stays in
    /// session for Check Out. Only the practice salon has her.
    static let pepperName = "Pepper"

    private static func addWaitingPet(in context: ModelContext) throws {
        let avaID = SampleData.avaClientID
        var descriptor = FetchDescriptor<Client>(predicate: #Predicate { $0.uuid == avaID })
        descriptor.fetchLimit = 1
        guard let ava = try context.fetch(descriptor).first else { return }
        let pepper = Pet(name: pepperName, species: .cat, gender: .female)
        pepper.setBreed("Domestic Shorthair")
        pepper.setColor("Tabby")
        pepper.owner = ava
        context.insert(pepper)
        ava.pets = (ava.pets ?? []) + [pepper]
    }

    private static func clearPracticeDefaults() {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }
}

/// Shown above the app while the practice salon is open, so nobody wonders
/// where their clients went.
struct PracticeSalonBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flask.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.ColorToken.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.localized("tour.practice.banner.title", value: "Practice salon"))
                    .font(.subheadline.weight(.semibold))
                Text(AppLocalization.localized("tour.practice.banner.message", value: "Your real clients are safe. Anything you do here disappears when the Academy ends."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.primary.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("practiceSalon.banner")
    }
}

extension EnvironmentValues {
    /// The view shows the Academy's practice salon, not the user's own.
    @Entry var isPracticeSalon = false
}
