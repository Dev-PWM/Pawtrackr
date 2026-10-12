//
//  DemoDataSeeder.swift
//  Pawtrackr
//
//  The sample salon: two practice clients with pets and visits, loaded only
//  when the user asks for them and the store is empty.
//

import Foundation
import SwiftData

enum DemoDataSeeder {
    /// Inserts the sample clients (fixed UUIDs, see `SampleData`) into an
    /// empty store. Returns false, changing nothing but the catalog check,
    /// when any client or pet already exists: sample rows must never land in
    /// a salon that has data.
    ///
    /// Callers decide whether seeding is allowed at all
    /// (`SampleDataSeedPolicy`); this is the last guard, run on the context
    /// that writes.
    ///
    /// The example prices it puts on unpriced catalog services are recorded
    /// in `userDefaults` (see `SamplePriceRecord`), so removing the sample
    /// clients on this device can take back the ones nobody changed since.
    @discardableResult
    static func seedIfNeeded(in context: ModelContext, userDefaults: UserDefaults = .standard) throws -> Bool {
        DataMigrations.ensureServiceCatalog(in: context)
        DataMigrations.ensureMessageTemplates(in: context)

        let clientCount = try context.fetchCount(FetchDescriptor<Client>())
        let petCount = try context.fetchCount(FetchDescriptor<Pet>())
        guard clientCount == 0, petCount == 0 else {
            if context.hasChanges {
                try context.save()
            }
            return false
        }

        let services = try context.fetch(FetchDescriptor<Service>(sortBy: [SortDescriptor(\.name)]))
        let pricedServices = applySamplePrices(to: services)

        // Fixed UUIDs go on right after init, before any setter: setters
        // schedule Spotlight items under the current UUID, and a visit's
        // session token is derived from its pet's UUID.
        let ava = Client(
            firstName: "Ava",
            lastName: "Martinez",
            phone: "3125550110",
            email: "ava@example.com"
        )
        ava.uuid = SampleData.avaClientID
        ava.setAddress("42 Cedar Street")

        let jordan = Client(
            firstName: "Jordan",
            lastName: "Lee",
            phone: "4155550142",
            email: "jordan@example.com"
        )
        jordan.uuid = SampleData.jordanClientID
        jordan.setAddress("18 Harbor Avenue")

        let milo = Pet(name: "Milo", species: .dog, gender: .male)
        milo.uuid = SampleData.miloPetID
        milo.setBreed("Mini Goldendoodle")
        milo.setColor("Apricot")
        milo.setPreferredGroomingFrequency(.monthly)
        milo.owner = ava
        ava.pets = [milo]

        let luna = Pet(name: "Luna", species: .dog, gender: .female)
        luna.uuid = SampleData.lunaPetID
        luna.setBreed("Shih Tzu")
        luna.setColor("White & Tan")
        luna.setPreferredGroomingFrequency(.monthly)
        luna.owner = jordan
        jordan.pets = [luna]

        context.insert(ava)
        context.insert(jordan)
        context.insert(milo)
        context.insert(luna)

        let now = Date()
        let activeVisit = Visit(pet: milo, startedAt: now.addingTimeInterval(-48 * 60))
        activeVisit.uuid = SampleData.miloActiveVisitID
        activeVisit.note = "Comfort breaks during drying help keep Milo relaxed."
        activeVisit.behaviorTags = ["Friendly", "Needs breaks"]
        context.insert(activeVisit)
        append(activeVisit, to: milo)

        var byName: [String: Service] = [:]
        for service in services where byName[service.name] == nil {
            byName[service.name] = service
        }

        var rebuiltDates: [Date] = []
        try addCompletedVisit(
            id: SampleData.miloRecentVisitID,
            pet: milo,
            endedAt: now.addingTimeInterval(-2 * 86_400),
            serviceNames: localizedServiceNames(["Full Package", "Paw Trim"]),
            paymentMethod: .cash,
            note: "Owner requested a shorter face tidy.",
            servicesByName: byName,
            context: context
        )
        rebuiltDates.append(now.addingTimeInterval(-2 * 86_400))

        try addCompletedVisit(
            id: SampleData.lunaRecentVisitID,
            pet: luna,
            endedAt: now.addingTimeInterval(-9 * 86_400),
            serviceNames: localizedServiceNames(["Bath", "Face Grooming"]),
            paymentMethod: .creditCard,
            note: "Coat detangled well after conditioning treatment.",
            servicesByName: byName,
            context: context
        )
        rebuiltDates.append(now.addingTimeInterval(-9 * 86_400))

        try addCompletedVisit(
            id: SampleData.miloOlderVisitID,
            pet: milo,
            endedAt: now.addingTimeInterval(-24 * 86_400),
            serviceNames: localizedServiceNames(["Haircut", "De-shedding"]),
            paymentMethod: .zelle,
            note: "First full seasonal reset after winter coat growth.",
            servicesByName: byName,
            context: context
        )
        rebuiltDates.append(now.addingTimeInterval(-24 * 86_400))

        try context.save()
        // Recorded only once the prices are saved, with the stamp they were
        // saved under: any later edit to the service moves that stamp.
        SamplePriceRecord.remember(pricedServices, userDefaults: userDefaults)

        for date in rebuiltDates {
            SummaryUpdater.rebuildDay(for: date, in: context)
        }
        if context.hasChanges {
            try context.save()
        }
        return true
    }

    private static func addCompletedVisit(
        id: UUID,
        pet: Pet,
        endedAt: Date,
        serviceNames: [String],
        paymentMethod: Payment.Method,
        note: String,
        servicesByName: [String: Service],
        context: ModelContext
    ) throws {
        let startedAt = endedAt.addingTimeInterval(-75 * 60)
        let visit = Visit(pet: pet, startedAt: startedAt)
        visit.uuid = id
        visit.note = note
        context.insert(visit)
        append(visit, to: pet)

        for serviceName in serviceNames {
            guard let service = servicesByName[serviceName] else { continue }
            let item = VisitItem.from(service: service, visit: visit)
            context.insert(item)
            visit.items = (visit.items ?? []) + [item]
        }

        let total = max(visit.calculatedTotal, Decimal(25))
        let reference = paymentMethod.requiresExternalReference ? "DEMO-\(Int.random(in: 1000...9999))" : nil
        let payment = Payment(amount: total, method: paymentMethod, paidAt: endedAt, externalReference: reference)
        context.insert(payment)
        visit.attachPayment(payment)
        visit.markCheckedOut(total: total, now: endedAt)
    }

    /// Example prices for the built-in catalog, so the sample checkout shows
    /// a subtotal. A price the salon already set is never touched, custom
    /// services are left alone, and nothing is enabled or disabled.
    static let samplePrices: [String: Decimal] = [
        "Full Package": 95,
        "Basic Package": 72,
        "Spa Package": 118,
        "Bath": 45,
        "Haircut": 60,
        "De-shedding": 24,
        "Anal Glands Expression": 18,
        "Face Grooming": 22,
        "Paw Trim": 16,
        "Hygiene Area Trim": 20,
        "Knots and Matting Fee": 30,
        "Flea & Ticks Treatment": 28,
        "Hair Dye": 35
    ]

    /// Returns the services it priced.
    private static func applySamplePrices(to services: [Service]) -> [Service] {
        var priced: [Service] = []
        for service in services where service.basePrice == nil {
            guard let englishName = DefaultServiceCatalog.englishName(forKnownName: service.name),
                  let price = samplePrices[englishName]
            else { continue }
            service.setBasePrice(price)
            priced.append(service)
        }
        return priced
    }

    /// Maps built-in English service identities to the active seed language.
    private static func localizedServiceNames(_ englishNames: [String]) -> [String] {
        englishNames.map(DefaultServiceCatalog.localizedName(forEnglishName:))
    }

    private static func append(_ visit: Visit, to pet: Pet) {
        var visits = pet.visits ?? []
        if !visits.contains(where: { $0.uuid == visit.uuid }) {
            visits.append(visit)
            pet.visits = visits
        }
    }
}

/// The example prices `DemoDataSeeder` put on this device's catalog: service
/// UUID, the price, and the `updatedAt` stamp the price was saved with.
///
/// Before this work `ensureServiceCatalog` cleared every catalog price on the
/// next launch, so example prices never outlived the first session. Now that
/// prices set in Settings are kept, the example ones would stay in the real
/// catalog after the sample clients are gone. "Remove Sample Clients" clears
/// a price only when the service still holds exactly the recorded price under
/// exactly the recorded stamp: any edit to the service since, even to the same
/// price, moves the stamp and the price stays.
///
/// The record lives in this device's UserDefaults, so removing the samples on
/// another device leaves the prices alone. That is the safe direction: a
/// price is never cleared without proof it is still the example one.
enum SamplePriceRecord {
    static let userDefaultsKey = "pawtrackr.sampleData.appliedPrices"

    struct Entry: Equatable, Hashable, Comparable {
        let serviceUUID: UUID
        let price: Decimal
        let stampedAt: Date

        static func < (lhs: Entry, rhs: Entry) -> Bool {
            lhs.serviceUUID.uuidString < rhs.serviceUUID.uuidString
        }

        /// Persisted dates keep millisecond precision, so a stamp that made a
        /// round trip may differ by less than that. A person's edit can't.
        func matches(_ service: Service) -> Bool {
            service.uuid == serviceUUID
                && service.basePrice == price
                && abs(service.updatedAt.timeIntervalSince(stampedAt)) < 0.001
        }
    }

    static func remember(_ services: [Service], userDefaults: UserDefaults) {
        guard !services.isEmpty else { return }
        var stored = userDefaults.dictionary(forKey: userDefaultsKey) ?? [:]
        for service in services {
            guard let price = service.basePrice else { continue }
            stored[service.uuid.uuidString] = [
                "price": NSDecimalNumber(decimal: price).stringValue,
                "stampedAt": service.updatedAt.timeIntervalSinceReferenceDate
            ]
        }
        userDefaults.set(stored, forKey: userDefaultsKey)
    }

    static func entries(userDefaults: UserDefaults) -> [Entry] {
        let stored = userDefaults.dictionary(forKey: userDefaultsKey) ?? [:]
        return stored.compactMap { key, value in
            guard let id = UUID(uuidString: key),
                  let fields = value as? [String: Any],
                  let priceText = fields["price"] as? String,
                  let price = Decimal(string: priceText, locale: Locale(identifier: "en_US_POSIX")),
                  let stamp = fields["stampedAt"] as? Double
            else { return nil }
            return Entry(serviceUUID: id, price: price, stampedAt: Date(timeIntervalSinceReferenceDate: stamp))
        }.sorted()
    }

    /// Services that still hold the example price they were given, untouched.
    static func untouchedServices(in context: ModelContext, userDefaults: UserDefaults) throws -> [Service] {
        var services: [Service] = []
        for entry in entries(userDefaults: userDefaults) {
            let id = entry.serviceUUID
            let matches = try context.fetch(FetchDescriptor<Service>(predicate: #Predicate { $0.uuid == id }))
            services += matches.filter(entry.matches)
        }
        return services
    }

    static func forget(userDefaults: UserDefaults) {
        userDefaults.removeObject(forKey: userDefaultsKey)
    }
}
