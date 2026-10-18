---
paths:
  - "Pawtrackr/Features/Loyalty/**"
  - "Pawtrackr/Core/Storage/Models/LoyaltyLedgerEntry.swift"
  - "PawtrackrTests/Loyalty*.swift"
---

# Loyalty Rules

- `LoyaltyEngine` is pure and integer-deterministic, so both earn paths (`CheckoutTransactionActor` and `LoyaltyService.applyPoints`) compute identical results on every device.
- Loyalty UI shows points, reward progress and history only; do not display membership tiers. Legacy tier calculations remain internal for compatibility. Completed, settled visits earn a flat 20 points regardless of those legacy values.
- `LoyaltyLedgerEntry` links to its client and visit by raw UUID, not SwiftData relationships.
- Balance mutations serialize through `LoyaltyMutationGate`.
