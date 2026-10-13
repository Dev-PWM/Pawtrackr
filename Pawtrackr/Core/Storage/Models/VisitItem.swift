//
//  VisitItem.swift
//  Pawtrackr
//
//  Created by mac on 8/17/25.
//  Updated by Assistant on 2025-09-03.
//

import Foundation
import SwiftData

/// A single line item on a Visit, representing a snapshot of a service at the time of the visit.
/// This ensures historical accuracy even if the original Service in the catalog is changed or deleted.
@Model
final class VisitItem {
    // MARK: - Properties
    // unique constraints. Identity is enforced by the SwiftData persistentModelID.
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: UUID = DeviceIdentity.currentID

    /// The name of the service, captured at the time the item was created.
    var name: String = ""

    /// The category of the service, captured at the time the item was created.
    var serviceCategoryRaw: String?

    /// The price for a single unit of this service, captured at the time the item was created.
    var unitPrice: Decimal = Decimal.zero

    /// The quantity of this service provided. Must be at least 1.
    var quantity: Int = 1

    /// Exact charged total when a cent allocation cannot be represented by a rounded unit price.
    /// Optional for inferred upgrades of shipped stores; legacy rows retain unit-price math.
    var reconciledLineTotal: Decimal?
    
    /// Optional notes specific to this line item.
    var note: String?

    // MARK: - Relationships
    
    /// The `Visit` this line item belongs to. If the visit is deleted, this item is also deleted.
    // FIX: The inverse side of a relationship is a plain property with NO @Relationship macro.
    // This resolves the "circular reference" build error.
    var visit: Visit?
    
    /// An optional link to the original `Service` in the catalog.
    /// If the `Service` is deleted, this link becomes `nil` but the historical record remains.
    var service: Service?

    // MARK: - Initializers
    
    /// Creates a line item by snapshotting a `Service` from the catalog.
    private init(service: Service, priceOverride: Decimal? = nil, note: String? = nil, visit: Visit) {
        self.uuid = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.lastModifiedBy = DeviceIdentity.currentID
        self.service = service
        self.visit = visit
        self.name = service.name.trimmed
        self.serviceCategoryRaw = service.category?.rawValue
        self.unitPrice = (priceOverride ?? service.effectiveBasePrice).roundedMoney()
        self.quantity = 1
        self.note = note
    }

    /// Creates a custom line item that does not link to a catalog `Service`.
    init(name: String, unitPrice: Decimal, quantity: Int = 1, note: String? = nil, visit: Visit) {
        self.uuid = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.lastModifiedBy = DeviceIdentity.currentID
        self.service = nil
        self.visit = visit
        self.name = name.trimmed
        self.serviceCategoryRaw = nil
        self.unitPrice = unitPrice.roundedMoney()
        self.quantity = max(1, quantity)
        self.note = note
    }

    // MARK: - Factory
    
    /// The preferred factory method for creating a `VisitItem` from a catalog `Service`.
    static func from(service: Service,
                     visit: Visit,
                     quantity: Int = 1,
                     priceOverride: Decimal? = nil,
                     note: String? = nil) -> VisitItem {
        let item = VisitItem(service: service, priceOverride: priceOverride, note: note, visit: visit)
        item.quantity = max(1, quantity)
        return item
    }

    // MARK: - Mutating API
    func setName(_ newName: String) {
        self.name = newName.trimmed
        didUpdate()
    }

    func setUnitPrice(_ newPrice: Decimal) {
        self.unitPrice = newPrice.roundedMoney()
        reconciledLineTotal = nil
        didUpdate()
    }

    func setQuantity(_ newQuantity: Int) {
        self.quantity = max(1, newQuantity)
        reconciledLineTotal = nil
        didUpdate()
    }

    /// Preserves quantity while retaining any indivisible cent remainder on the line.
    func setReconciledLineTotal(_ total: Decimal) {
        let charged = max(.zero, total.roundedMoney())
        unitPrice = (charged / Decimal(max(1, quantity))).roundedMoney()
        reconciledLineTotal = unitPrice * Decimal(quantity) == charged ? nil : charged
        didUpdate()
    }

    // MARK: - Derived Properties & Formatting
    
    var lineTotal: Decimal {
        reconciledLineTotal ?? (unitPrice * Decimal(quantity)).roundedMoney()
    }
    
    @MainActor
    var unitPriceString: String {
        unitPrice.moneyString
    }
    
    @MainActor
    var lineTotalString: String {
        lineTotal.moneyString
    }

    // Alias used by some views (e.g., VisitDetailView)
    @MainActor
    var lineTotalCurrencyString: String {
        lineTotal.moneyString
    }
    
    @MainActor
    var receiptLine: String {
        let qtyString = quantity > 1 ? " ×\(quantity)" : ""
        return "\(name)\(qtyString) • \(lineTotalString)"
    }

    var displayName: String { name }

    private func didUpdate() {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
    }
}
