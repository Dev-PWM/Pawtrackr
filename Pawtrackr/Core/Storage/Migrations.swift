//
//  Migrations.swift
//  Pawtrackr
//
//  Store schema (model list) and one-time data seeding/coercion.
//

import Foundation
import SwiftData
import OSLog

// MARK: - Schema
//
// The store is opened WITHOUT a SwiftData staged migration plan. Upgrades rely
// on SwiftData's automatic (inferred) lightweight migration, which works from
// any shipped build because Core Data keeps a copy of each store's model inside
// the SQLite file (`Z_MODELCACHE`). See docs/adr/0004-inferred-lightweight-migration.md.
//
// Why not a staged plan: staged migration only opens a store whose on-disk model
// exactly matches one of the plan's versioned schemas. 1.0.2 shipped a plan that
// listed the live model classes (and had edited the already-shipped V1), so no
// 1.0.1 store matched. Every upgrading user hit NSCocoaErrorDomain 134504
// ("Cannot use staged migration with an unknown model version") and landed on
// the recovery screen. Keep existing model types and fields compatible with
// those stores, including legacy metadata, when opening them locally.
//
// When you change a model, keep the change additive:
//   - New @Model types, new properties that are optional or have a default,
//     new optional relationships. Rename with `@Attribute(originalName:)`.
//     Never delete or retype a property that has shipped.
//   - `StoreUpgradeRegressionTests` opens real stores captured from shipped
//     builds. When a release ships, add its store to PawtrackrTests/Fixtures.

/// Every model in the store. The rest of the app builds its `Schema` from this.
enum PawtrackrSchema {
    static var models: [any PersistentModel.Type] {
        [
            Client.self, Pet.self, Visit.self, VisitItem.self, Service.self, Payment.self, User.self,
            DaySummary.self, ServiceDaySummary.self, CategoryDaySummary.self, ClientInsightSummary.self,
            CheckoutTransaction.self, EmergencyContact.self, BusinessConfig.self, MessageTemplate.self,
            InventoryItem.self, InventoryTransaction.self, DeviceMetadata.self, PresenceRecord.self,
            // Added after 1.0.1 (July 2026). Additive, so inferred migration adds their tables.
            LoyaltyLedgerEntry.self, LoyaltyConfig.self, LoyaltyRewardTemplate.self, AppNotification.self
        ]
    }
}


// MARK: - Data Seeding & Coercion

enum DataMigrations {
    static func backfillVisitSessionTokens(in context: ModelContext) {
        do {
            let visits = try context.fetch(FetchDescriptor<Visit>())
            var updates = 0
            for visit in visits where visit.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                visit.ensureSessionToken()
                updates += 1
            }
            if context.hasChanges {
                try context.save()
            }
            if updates > 0 {
                Logger.migrations.info("Backfilled \(updates) visit session token(s).")
            }
        } catch {
            Logger.migrations.error("Visit session token backfill failed: \(String(describing: error))")
        }
    }

    static func coercePets(in context: ModelContext) {
        do {
            let sortDescriptors = [SortDescriptor(\Pet.createdAt, order: .forward)]
            let batchSize = 500
            var offset = 0
            var updates = 0

            while true {
                var descriptor = FetchDescriptor<Pet>(sortBy: sortDescriptors)
                descriptor.fetchLimit = batchSize
                descriptor.fetchOffset = offset

                let pets = try context.fetch(descriptor)
                if pets.isEmpty { break }

                var batchChanged = false
                for pet in pets {
                    var changed = false
                    // Species is already constrained to .dog/.cat at type level now.
                    // Gender: ensure either .male or .female. If not, default to .male.
                    if pet.gender != .male && pet.gender != .female {
                        pet.gender = .male
                        changed = true
                    }

                    if changed { updates += 1; batchChanged = true }
                }

                if batchChanged {
                    try context.save()
                }

                offset += pets.count
            }

            if updates > 0 {
                Logger.migrations.info("Coerced \(updates) pet records for narrowed enums.")
            }
        } catch {
            Logger.migrations.error("Migration failed: \(String(describing: error))")
        }
    }



    /// Build or refresh DaySummary rows from existing completed visits.
    /// Safe to run multiple times; it re-computes aggregates per distinct day.
    static func backfillDaySummaries(in context: ModelContext) {
        do {
            let completedDesc = FetchDescriptor<Visit>(
                predicate: #Predicate { $0.endedAt != nil },
                sortBy: [SortDescriptor(\.endedAt, order: .forward)]
            )
            let visits = try context.fetch(completedDesc)
            let cal = Calendar.current
            var byDay: [Date: (Decimal, Int)] = [:]
            for v in visits {
                guard let end = v.endedAt else { continue }
                let day = cal.startOfDay(for: end)
                var agg = byDay[day] ?? (.zero, 0)
                agg.0 += v.total
                agg.1 += 1
                byDay[day] = agg
            }

            SummaryUpdater.dedupeSummaryCaches(in: context)

            // Fetch existing summaries to upsert
            let existing = try context.fetch(FetchDescriptor<DaySummary>())
            let index = SummaryUpdater.collapsedDayAggregates(from: existing)
            var rowsByDay: [Date: DaySummary] = [:]
            for row in existing where index[row.day] != nil {
                if let current = rowsByDay[row.day] {
                    if row.visitCount > current.visitCount ||
                        (row.visitCount == current.visitCount && row.revenue > current.revenue) {
                        rowsByDay[row.day] = row
                    }
                } else {
                    rowsByDay[row.day] = row
                }
            }

            var updated = 0, inserted = 0
            for (day, (rev, cnt)) in byDay {
                if let s = rowsByDay[day] {
                    if s.revenue != rev || s.visitCount != cnt { s.revenue = rev; s.visitCount = cnt; updated += 1 }
                } else {
                    context.insert(DaySummary(day: day, revenue: rev, visitCount: cnt)); inserted += 1
                }
            }
            if inserted + updated > 0 { try context.save() }
            Logger.migrations.info("DaySummary backfill: inserted=\(inserted), updated=\(updated)")
        } catch {
            Logger.migrations.error("DaySummary backfill failed: \(String(describing: error))")
        }
    }

    /// Ensure the service catalog exists with the current set of packages/add-ons.
    ///
    /// Runs on every launch on every device, so it only writes what differs:
    /// SwiftData uploads every row a property is assigned on, even to the same
    /// value. Prices and the enabled switch belong to the salon. This used to
    /// clear every catalog price and re-enable every catalog service on each
    /// launch, which undid prices set in Settings → Services and brought back
    /// services the salon had turned off. It no longer touches either. There is
    /// no one-time "strip default prices" pass either: every build since the
    /// catalog shipped stripped prices on each launch, so no store still holds
    /// an old default, and a one-time pass would only erase prices the salon
    /// entered since its last launch.
    static func ensureServiceCatalog(in context: ModelContext) {
        let desired = DefaultServiceCatalog.definitions

        do {
            let existing = try context.fetch(FetchDescriptor<Service>())
            var byName: [String: Service] = [:]
            existing.forEach { byName[$0.name.lowercased()] = $0 }
            let knownNamesByEnglishName = DefaultServiceCatalog.allKnownLocalizedNamesByEnglishName

            for def in desired {
                let targetName = def.localizedName
                let candidateNames = knownNamesByEnglishName[def.englishName] ?? [def.englishName.lowercased()]
                let svc = candidateNames.compactMap { byName[$0] }.first

                if let svc {
                    normalizeCatalogAttributes(of: svc, to: def, name: targetName)
                } else {
                    let svc = Service(
                        name: targetName,
                        category: def.category,
                        systemIcon: def.icon,
                        basePrice: nil,
                        isEnabled: true,
                        isPackage: def.isPackage
                    )
                    context.insert(svc)
                }
            }

            // "Basic Groom" was retired from checkout. Still switched off each
            // launch, but only when it isn't already off and unpriced.
            for svc in existing where svc.isObsoleteCheckoutService {
                if svc.isEnabled {
                    svc.setEnabled(false)
                }
                if svc.basePrice != nil {
                    svc.setBasePrice(nil)
                }
            }

            // Persist any updates/inserts.
            if context.hasChanges {
                try context.save()
            }
        } catch {
            Logger.migrations.error("ensureServiceCatalog failed: \(String(describing: error))")
        }
    }

    /// Name, category, icon and the package flag follow the built-in
    /// definition. Each is assigned only when it differs, compared the way the
    /// setter would store it, so an unchanged catalog saves nothing.
    private static func normalizeCatalogAttributes(of svc: Service, to def: DefaultServiceCatalog.Definition, name targetName: String) {
        if svc.name != TextInputLimits.clamped(targetName, to: TextInputLimits.name) {
            svc.rename(targetName)
        }
        if svc.categoryRaw != def.category?.rawValue {
            svc.setCategory(def.category)
        }
        let targetIcon = def.icon.map { TextInputLimits.clamped($0, to: TextInputLimits.shortText) }
        if svc.systemIcon != targetIcon {
            svc.setSystemIcon(def.icon)
        }
        if svc.isPackage != def.isPackage {
            svc.isPackage = def.isPackage
            svc.updatedAt = .now
            svc.lastModifiedBy = DeviceIdentity.currentID
        }
    }

    /// Backfill `.earned` loyalty ledger entries for visits that awarded points
    /// before the ledger existed, and collapse legacy backfill duplicates.
    /// Idempotent: keyed by visit UUID, safe to run on every launch.
    static func backfillLoyaltyLedger(in context: ModelContext) {
        do {
            let earnedRaw = LoyaltyLedgerEntry.Kind.earned.rawValue
            let earnedEntries = try context.fetch(
                FetchDescriptor<LoyaltyLedgerEntry>(
                    predicate: #Predicate<LoyaltyLedgerEntry> { $0.kindRaw == earnedRaw }
                )
            )

            // Dedupe: keep the earliest-created entry per visit.
            var byVisit: [UUID: LoyaltyLedgerEntry] = [:]
            var removed = 0
            for entry in earnedEntries {
                guard let visitUUID = entry.visitUUID else { continue }
                if let kept = byVisit[visitUUID] {
                    let loser = entry.createdAt < kept.createdAt ? kept : entry
                    let winner = entry.createdAt < kept.createdAt ? entry : kept
                    byVisit[visitUUID] = winner
                    context.delete(loser)
                    removed += 1
                } else {
                    byVisit[visitUUID] = entry
                }
            }

            // Backfill pre-ledger visit earns. Historical balances are unknowable,
            // so `balanceAfter` stays nil on backfilled rows.
            let visits = try context.fetch(
                FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.loyaltyPointsChange != 0 })
            )
            var inserted = 0
            for visit in visits where byVisit[visit.uuid] == nil {
                guard let client = visit.pet?.owner else { continue }
                let entry = LoyaltyLedgerEntry(
                    kind: .earned,
                    points: visit.loyaltyPointsChange,
                    clientUUID: client.uuid,
                    visitUUID: visit.uuid,
                    balanceAfter: nil,
                    reason: visit.pet?.name,
                    createdAt: visit.endedAt ?? visit.startedAt
                )
                context.insert(entry)
                byVisit[visit.uuid] = entry
                inserted += 1
            }

            if context.hasChanges {
                try context.save()
            }
            if inserted > 0 || removed > 0 {
                Logger.migrations.info("Loyalty ledger backfill: inserted=\(inserted), dedupedAway=\(removed)")
            }
        } catch {
            Logger.migrations.error("Loyalty ledger backfill failed: \(String(describing: error))")
        }
    }

    /// Keeps exactly one of each built-in message template, in the app's language.
    ///
    /// Defaults used to be matched by their localized title, so changing the app
    /// language seeded a second, translated set. Templates are now matched by
    /// type, or by any shipped wording for legacy rows saved with an old type.
    /// Nothing in the app creates or edits built-in templates, so extra copies
    /// are seeded duplicates and are deleted. A kept copy that still has a
    /// shipped wording is switched to the current language; other text is left
    /// alone. Custom templates are never touched.
    static func ensureMessageTemplates(in context: ModelContext) {
        do {
            let existing = try context.fetch(FetchDescriptor<MessageTemplate>())
            var claimed = Set<PersistentIdentifier>()
            var removed = 0

            for template in MessageTemplate.defaults {
                let type = template.type
                let wordings = MessageTemplate.shippedWordings(for: type)
                let matches = existing.filter { candidate in
                    guard !claimed.contains(candidate.persistentModelID) else { return false }
                    if candidate.type == type { return true }
                    return candidate.type == .custom && wordings.contains {
                        $0.title == candidate.title || $0.content == candidate.content
                    }
                }

                guard !matches.isEmpty else {
                    context.insert(template)
                    continue
                }

                // Deterministic, so two contexts reconciling at once keep the same row.
                let keep = matches.min { lhs, rhs in
                    let lhsCurrent = lhs.title == template.title
                    let rhsCurrent = rhs.title == template.title
                    if lhsCurrent != rhsCurrent { return lhsCurrent }
                    return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
                }!
                claimed.formUnion(matches.map(\.persistentModelID))

                if keep.typeRaw != type.rawValue { keep.typeRaw = type.rawValue }
                let isShippedWording = wordings.contains { $0.title == keep.title && $0.content == keep.content }
                if isShippedWording {
                    if keep.title != template.title { keep.title = template.title }
                    if keep.content != template.content { keep.content = template.content }
                }
                for duplicate in matches where duplicate.persistentModelID != keep.persistentModelID {
                    context.delete(duplicate)
                    removed += 1
                }
            }

            if context.hasChanges {
                try context.save()
            }
            if removed > 0 {
                Logger.migrations.info("Message templates: removed \(removed) duplicate default(s)")
            }
        } catch {
            Logger.migrations.error("ensureMessageTemplates failed: \(String(describing: error))")
        }
    }

    static func ensureLoyaltyDefaults(in context: ModelContext) {
        do {
            var didChange = false

            let configDescriptor = FetchDescriptor<LoyaltyConfig>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let configs = try context.fetch(configDescriptor)
            if configs.isEmpty {
                context.insert(LoyaltyConfig())
                didChange = true
            } else if configs.count > 1 {
                didChange = collapseDuplicateLoyaltyConfigs(configs, in: context)
            }

            let existingRewards = try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
            if existingRewards.isEmpty {
                for template in LoyaltyRewardTemplate.seedTemplates() {
                    context.insert(template)
                    didChange = true
                }
            }

            if didChange || context.hasChanges {
                try context.save()
            }
        } catch {
            Logger.migrations.error("ensureLoyaltyDefaults failed: \(String(describing: error))")
        }
    }

    /// Merges duplicate loyalty settings field-by-field before deleting extras.
    private static func collapseDuplicateLoyaltyConfigs(_ configs: [LoyaltyConfig], in context: ModelContext) -> Bool {
        guard configs.count > 1 else { return false }

        let canonical = configs.min { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.updatedAt < rhs.updatedAt
        } ?? configs[0]
        let defaults = LoyaltyConfigSnapshot.default
        let newestFirst = configs.sorted { lhs, rhs in
            loyaltyConfigIsNewer(lhs, than: rhs)
        }

        if let earnMode = newestFirst.first(where: { $0.earnMode != defaults.earnMode })?.earnMode,
           canonical.earnMode != earnMode {
            canonical.setEarnMode(earnMode)
        }
        if let pointsPerDollar = newestFirst.first(where: { $0.pointsPerDollar != defaults.pointsPerDollar })?.pointsPerDollar,
           canonical.pointsPerDollar != pointsPerDollar {
            canonical.setPointsPerDollar(pointsPerDollar)
        }
        if let pointsPerVisit = newestFirst.first(where: { $0.pointsPerVisit != defaults.pointsPerVisit })?.pointsPerVisit,
           canonical.pointsPerVisit != pointsPerVisit {
            canonical.setPointsPerVisit(pointsPerVisit)
        }
        if let redemptionThreshold = newestFirst.first(where: { $0.redemptionThreshold != defaults.redemptionThreshold })?.redemptionThreshold,
           canonical.redemptionThreshold != redemptionThreshold {
            canonical.setRedemptionThreshold(redemptionThreshold)
        }
        if let isRewardsCatalogEnabled = newestFirst.first(where: { $0.isRewardsCatalogEnabled != defaults.isRewardsCatalogEnabled })?.isRewardsCatalogEnabled,
           canonical.isRewardsCatalogEnabled != isRewardsCatalogEnabled {
            canonical.setRewardsCatalogEnabled(isRewardsCatalogEnabled)
        }

        for duplicate in configs where duplicate !== canonical {
            context.delete(duplicate)
        }
        canonical.markModified()
        return true
    }

    /// Orders loyalty settings so reconciliation prefers the most recent field source.
    private static func loyaltyConfigIsNewer(_ lhs: LoyaltyConfig, than rhs: LoyaltyConfig) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.createdAt > rhs.createdAt
    }
}

extension Logger {
    static let migrations = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "migrations")
}
