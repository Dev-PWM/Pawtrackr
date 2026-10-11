//
//  Visit.swift
//  Pawtrackr
//
//  Canonical Visit model for SwiftData
//

import Foundation
import OSLog
import SwiftData

@Model
final class Visit {
    #Index<Visit>([\.startedAt], [\.endedAt], [\.createdAt])

    // MARK: - Identity & Timestamps
    var uuid: UUID = UUID()
    var sessionToken: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var startedAt: Date = Date()
    var endedAt: Date?
    var lastModifiedBy: UUID = DeviceIdentity.currentID
    var lastModifiedAt: Date = Date()
    var loyaltyPointsChange: Int = 0
    /// Checkout reward summaries are additive; the signed audit trail stays in the ledger.
    var loyaltyRedeemedPoints: Int = 0
    var loyaltyRewardTitle: String? = nil
    var loyaltyCreditApplied: Decimal = Decimal.zero

    // MARK: - Notes & Media
    var note: String?
    var behaviorTagsRaw: String = ""
    @Transient
    var behaviorTags: [String] {
        get { Self.decodeBehaviorTags(from: behaviorTagsRaw) }
        set { behaviorTagsRaw = Self.encodeBehaviorTags(newValue) }
    }
    @Attribute(.externalStorage) var beforePhotoData: Data?
    @Attribute(.externalStorage) var afterPhotoData: Data?
    @Attribute(.externalStorage) var beforeThumbnailData: Data?
    @Attribute(.externalStorage) var afterThumbnailData: Data?

    // MARK: - Money
    /// Persisted grand total for this visit (non-optional, stored).
    /// IMPORTANT: do not duplicate/extend this with another property named `total`.
    var total: Decimal = Decimal.zero

    // MARK: - Relationships
    /// The pet this visit belongs to. Optional to allow SwiftData cascade deletes to work properly.
    var pet: Pet?

    @Relationship(deleteRule: .cascade, inverse: \VisitItem.visit)
    var items: [VisitItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \Payment.visit)
    var payment: Payment?

    var user: User?

    // MARK: - Init
    init(pet: Pet, startedAt: Date = .now, user: User? = nil) {
        self.uuid = UUID()
        self.sessionToken = Self.makeSessionToken(petUUID: pet.uuid, startedAt: startedAt)
        self.createdAt = .now
        self.updatedAt = .now
        self.startedAt = startedAt
        self.pet = pet
        self.user = user
        self.lastModifiedBy = DeviceIdentity.currentID
        self.lastModifiedAt = .now
    }

    // MARK: - Derived Properties
    var isCompleted: Bool { endedAt != nil }
    var isActive: Bool { endedAt == nil }
    var isPaid: Bool { payment != nil }

    var duration: TimeInterval? {
        guard let endedAt = endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Formatted duration. Uses `endedAt` when completed, otherwise time-since-start.
    @MainActor
    var durationString: String {
        Formatters.durationString(from: startedAt, to: endedAt ?? Date())
    }

    @MainActor
    var totalCurrencyString: String {
        Formatters.currencyString(total)
    }

    /// Falls back to a freshly computed total if `total` was never stamped
    /// (e.g. in-progress visits surfaced in revenue rollups).
    var effectiveTotal: Decimal {
        total > 0 ? total : calculatedTotal
    }

    /// Primary date used for sorting and reports.
    var sortKeyDate: Date { endedAt ?? startedAt }

    /// Sum of line totals without mutating the stored `total`.
    var calculatedTotal: Decimal {
        (items ?? []).reduce(Decimal.zero) { $0 + $1.lineTotal }
    }

    var servicesSubtotal: Decimal {
        calculatedTotal
    }

    /// Finalize a visit: stamp the total and close-out time. Mirrors the
    /// CheckoutTransactionActor exit path used by every checkout flow.
    func markCheckedOut(total: Decimal, now: Date = .now) {
        self.total = total
        self.endedAt = now
        didUpdate()
    }

    func markCheckedOut(now: Date = .now) {
        markCheckedOut(total: effectiveTotal, now: now)
    }

    // MARK: - Mutating API
    func setStartedAt(_ date: Date) {
        startedAt = date
        refreshSessionToken()
        didUpdate()
    }
    
    func setEndedAt(_ date: Date?) {
        endedAt = date
        didUpdate()
    }

    func setNote(_ value: String?) {
        note = value
        didUpdate()
    }

    func setBehaviorTags(_ tags: [String]) {
        behaviorTags = tags.map { $0.trimmed }.filter { !$0.isEmpty }
        didUpdate()
    }

    func addBehaviorTag(_ tag: String) {
        let t = tag.trimmed
        guard !t.isEmpty else { return }
        var tags = behaviorTags
        if !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            tags.append(t)
            behaviorTags = tags
            didUpdate()
        }
    }

    func setBeforePhoto(_ data: Data?) {
        if let data = data {
            beforePhotoData = LocalMediaPolicy.optimizedFullImageData(data, context: AppLocalization.localized("media.visit_before_photo", value: "visit before photo"))
            beforeThumbnailData = LocalMediaPolicy.optimizedThumbnailData(data)
        } else {
            beforePhotoData = nil
            beforeThumbnailData = nil
        }
        didUpdate()
    }

    func setAfterPhoto(_ data: Data?) {
        if let data = data {
            afterPhotoData = LocalMediaPolicy.optimizedFullImageData(data, context: AppLocalization.localized("media.visit_after_photo", value: "visit after photo"))
            afterThumbnailData = LocalMediaPolicy.optimizedThumbnailData(data)
        } else {
            afterPhotoData = nil
            afterThumbnailData = nil
        }
        didUpdate()
    }

    func addItem(_ item: VisitItem) {
        var currentItems = items ?? []
        if !currentItems.contains(where: { $0 === item }) {
            currentItems.append(item)
            items = currentItems
            recalculateTotal()
            didUpdate()
        }
    }

    func removeItem(_ item: VisitItem) {
        var currentItems = items ?? []
        if let idx = currentItems.firstIndex(where: { $0 === item }) {
            currentItems.remove(at: idx)
            items = currentItems
            recalculateTotal()
            didUpdate()
        }
    }

    func recalculateTotal() {
        total = (items ?? []).reduce(Decimal.zero) { $0 + $1.lineTotal }
    }

    /// Short-name alias used by checkout flows.
    func recalcTotal() { recalculateTotal() }

    /// Assigns pre-optimized photo blobs directly. Callers must already have
    /// run the data through `LocalMediaPolicy` (the checkout pipeline does).
    func applyPhotos(before: Data?, beforeThumb: Data?, after: Data?, afterThumb: Data?) {
        beforePhotoData = before
        beforeThumbnailData = beforeThumb
        afterPhotoData = after
        afterThumbnailData = afterThumb
        didUpdate()
    }

    /// Convenience that constructs a `VisitItem` and appends it. Use this
    /// when you have raw fields (a service may be linked for catalog lookup).
    func addItem(title: String, unitPrice: Decimal, quantity: Int = 1, service: Service? = nil) {
        let item: VisitItem
        if let service {
            item = VisitItem.from(service: service, visit: self, quantity: quantity, priceOverride: unitPrice)
        } else {
            item = VisitItem(name: title, unitPrice: unitPrice, quantity: quantity, visit: self)
        }
        addItem(item)
    }

    func attachPayment(_ payment: Payment) {
        self.payment = payment
        payment.visit = self
        didUpdate()
    }

    static func makeSessionToken(petUUID: UUID, startedAt: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: startedAt)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d_%@", year, month, day, petUUID.uuidString)
    }

    func ensureSessionToken() {
        if sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refreshSessionToken()
        }
    }

    // MARK: - Private Helpers
    private func refreshSessionToken() {
        if let pet {
            sessionToken = Self.makeSessionToken(petUUID: pet.uuid, startedAt: startedAt)
        }
    }

    private func didUpdate() {
        ensureSessionToken()
        updatedAt = .now
        lastModifiedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
        
        // Only attempt to update the client's last visit date if we can safely reach it.
        if let owner = pet?.owner {
            let candidate = sortKeyDate
            if let existing = owner.lastVisitDate {
                if candidate > existing { owner.lastVisitDate = candidate }
            } else {
                owner.lastVisitDate = candidate
            }
        }
    }

    private static func decodeBehaviorTags(from raw: String) -> [String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func encodeBehaviorTags(_ tags: [String]) -> String {
        let cleaned = tags.map { $0.trimmed }.filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(cleaned),
              let raw = String(data: data, encoding: .utf8) else {
            return ""
        }
        return raw
    }
}
