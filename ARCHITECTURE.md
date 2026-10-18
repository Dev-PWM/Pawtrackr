# Pawtrackr Architecture

Constraints and historical reasons live in `AGENTS.md`; subsystem rules live alongside code. This file maps runtime boundaries.

- `ClientRepository` and `ClientCreationCoordinator` serialize client writes. View models receive identifiers or Sendable snapshots; presentation contexts resolve current models without discarding unsaved edits.
- `CheckoutViewModel` owns the four-step draft. `CheckoutDraftStore` orders background file I/O; `CheckoutTransactionActor` commits payment, visit, loyalty and rollups atomically.
- `LocalStoreCommitBridge` observes saves and `GlobalEventBus` invalidates client, dashboard and insights presentations. ID refetches alone do not refresh already-materialized models.
- `SummaryUpdater` rebuilds daily summaries with equality-checked writes. Insights reads operate through `InsightsActor`.
- Store bootstrap and recovery precede container creation. ADR-0003/0004 explain additive upgrades; ADR-0005 records local-only persistence. Shipped fixtures are documented in `PawtrackrTests/Fixtures/StoreFixtures.md`.

Verification outcomes belong in root `CHECKLIST.md`; decisions belong in `docs/adr/`.
