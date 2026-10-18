//
//  UITestDataSeeder.swift
//  Pawtrackr
//
//  Seeds deterministic in-memory data for UI automation only.
//

import Foundation
import SwiftData

enum UITestDataSeeder {
    static func seedIfNeeded(in context: ModelContext) throws {
        // Onboarding test mode: skip seeding ANY data so the onboarding flow
        // takes over on launch. The XCUI test then drives every step.
        if AppRuntime.isOnboardingTestMode {
            return
        }
        try seedBusinessConfig(in: context)
        DataMigrations.ensureServiceCatalog(in: context)

        let services = try context.fetch(FetchDescriptor<Service>(sortBy: [SortDescriptor(\.name)]))
        applyCheckoutPrices(to: services)

        let clientCount = try context.fetchCount(FetchDescriptor<Client>())
        if clientCount > 0 {
            if context.hasChanges {
                try context.save()
            }
            return
        }

        #if DEBUG
        // The stress book is written asynchronously after the commit bridge is installed.
        if AppRuntime.shouldSeedSearchStressFixture {
            try context.save()
            return
        }
        #endif

        let owner = Client(
            firstName: "UITest",
            lastName: "Owner",
            phone: "3125550100",
            email: "uitest.owner@example.com"
        )
        // The walkthrough UI tests practise on this client, so it carries the
        // sample UUIDs: the tour only opens and acts on sample clients.
        owner.uuid = SampleData.avaClientID
        owner.setAddress("100 Grooming Lane")

        let pet = Pet(name: "UITest Pet", species: .dog, gender: .female)
        pet.uuid = SampleData.miloPetID
        pet.setBreed("Poodle")
        pet.setColor("Apricot")
        pet.setPreferredGroomingFrequency(.monthly)
        if ProcessInfo.processInfo.environment["PAWTRACKR_UI_BEHAVIOR_SCENARIO"] == "aggressive-special-needs" {
            pet.setBehaviorTags(["Aggressive", "Special Needs"])
        } else if let raw = ProcessInfo.processInfo.environment["PAWTRACKR_UI_BEHAVIOR_SCENARIO"],
                  let behavior = Pet.BehaviorTag(rawValue: raw) {
            pet.setBehaviorTags([behavior.displayName])
        }
        pet.owner = owner
        owner.pets = [pet]

        context.insert(owner)
        context.insert(pet)

        let now = Date()
        let activeVisit = Visit(pet: pet, startedAt: now.addingTimeInterval(-42 * 60))
        activeVisit.uuid = SampleData.miloActiveVisitID
        context.insert(activeVisit)
        append(activeVisit, to: pet)

        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        let completedSpecs: [(daysAgo: Int, services: [String], method: Payment.Method)] = [
            (1, localizedServiceNames(["Full Package", "Paw Trim"]), .cash),
            (5, localizedServiceNames(["Bath", "De-shedding"]), .creditCard),
            (14, localizedServiceNames(["Haircut", "Face Grooming"]), .zelle),
            (35, localizedServiceNames(["Spa Package"]), .debitCard)
        ]

        var summaryDates: [Date] = []
        for (index, spec) in completedSpecs.enumerated() {
            let endedAt = now.addingTimeInterval(TimeInterval(-spec.daysAgo * 86_400))
            let startedAt = endedAt.addingTimeInterval(TimeInterval(-75 * 60 - index * 180))
            let visit = Visit(pet: pet, startedAt: startedAt)
            context.insert(visit)
            append(visit, to: pet)

            for serviceName in spec.services {
                guard let service = byName[serviceName] else { continue }
                let item = VisitItem.from(service: service, visit: visit)
                context.insert(item)
                visit.items = (visit.items ?? []) + [item]
            }

            let total = max(visit.calculatedTotal, Decimal(25))
            let reference = spec.method.requiresExternalReference ? "UITEST-\(1000 + index)" : nil
            let payment = Payment(amount: total, method: spec.method, paidAt: endedAt, externalReference: reference)
            context.insert(payment)
            visit.attachPayment(payment)
            visit.markCheckedOut(total: total, now: endedAt)
            summaryDates.append(endedAt)
        }

        try context.save()

        for date in summaryDates {
            SummaryUpdater.rebuildDay(for: date, in: context)
        }

        DataMigrations.ensureMessageTemplates(in: context)
    }

    private static func seedBusinessConfig(in context: ModelContext) throws {
        let configs = try context.fetch(FetchDescriptor<BusinessConfig>())
        if let config = configs.first {
            // Only update if setup is NOT complete (legacy or empty state)
            if !config.isSetupComplete {
                config.name = "Pawtrackr UI Test Grooming"
                config.isSetupComplete = true
            }
        } else {
            let config = BusinessConfig(
                name: "Pawtrackr UI Test Grooming",
                email: "hello@example.com",
                phone: "3125550100",
                address: "100 Grooming Lane"
            )
            config.isSetupComplete = true
            context.insert(config)
        }
    }

    private static func applyCheckoutPrices(to services: [Service]) {
        let prices: [String: Decimal] = [
            "Full Package": 95,
            "Basic Package": 70,
            "Spa Package": 110,
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

        for service in services {
            let englishName = DefaultServiceCatalog.englishName(forKnownName: service.name) ?? service.name
            service.setBasePrice(prices[englishName] ?? 25)
            service.setEnabled(true)
        }
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
