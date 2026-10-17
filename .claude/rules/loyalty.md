---
paths:
  - "Pawtrackr/Features/Loyalty/**"
  - "Pawtrackr/Core/Storage/Models/LoyaltyLedgerEntry.swift"
---

# Loyalty Rules

- `LoyaltyEngine` is pure and integer-deterministic, so both earn paths (`CheckoutTransactionActor` and `LoyaltyService.applyPoints`) compute identical results on every device.
- Tiers derive from `lifetimeEarnedPoints`; redeeming points never demotes a tier.
- `LoyaltyLedgerEntry` links to its client and visit by raw UUID, not SwiftData relationships.
- Balance mutations serialize through `LoyaltyMutationGate`.
