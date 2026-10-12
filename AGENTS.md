# Pawtrackr Architecture Memory

## Checkout Pilot Decisions

- `CheckoutViewModel` is the only owner of checkout UI state. `CheckoutView` can bind to editor buffers, but every persisted value must flow back through the view model before navigation or confirmation.
- Checkout money is Decimal-only. Service subtotal, manual amount overrides, tips, payments, and line-item reconciliation must avoid `Double` currency math.
- The 4-step checkout draft is a crash-recovery boundary. Step transitions, payment method changes, external references, and tips are critical state and must be saved immediately through `CheckoutDraftStore`.
- Draft disk I/O belongs off the main actor. `CheckoutDraftStore` remains an actor for serialization, while JSON/file reads and writes execute through detached utility tasks.
- Confirm-and-pay is protected at two layers: a UI/view-model debounce blocks rapid duplicate taps, and `CheckoutTransactionActor` keeps persistence idempotent by visit UUID.
- Checkout success must not hide cleanup or refresh failures. Draft deletion and main-context refresh errors are logged instead of swallowed with `try?`.

## Data Store Pilot Decisions

- Pawtrackr stores data locally. `LocalStoreConfiguration` explicitly disables cloud persistence (`cloudKitDatabase: .none`) while preserving the shipped named store URL and model schema. Legacy device/presence models remain solely for store compatibility; do not restore cloud UI, permissions, sync engines, or ubiquitous settings.

- `DataStoreService` is the central SwiftData access facade. The production initializer accepts an existing `ModelContainer`; test and QualityControl code can use the `inMemory` initializer.
- Background fetches must create a detached `ModelContext` from the shared `ModelContainer`; UI-bound fetches remain on the main actor.
- The store opens WITHOUT a SwiftData `SchemaMigrationPlan` (ADR-0004). 1.0.2 shipped a staged plan built from live model classes, every 1.0.1 store failed with 134504, and users reset their clients away. Keep model changes additive (new models, optional/defaulted properties, `@Attribute(originalName:)` renames); CI fails if `migrationPlan:` reappears.
- Every release adds its store to `PawtrackrTests/Fixtures` (see `StoreFixtures.md`); `StoreUpgradeRegressionTests` must open all of them. Before shipping, install the previous App Store build, add data, then install the new build over it without deleting.
- Store-file work (scheduled restore, per-build backup, legacy move) runs only in `PawtrackrApp.init`, before any container opens. Nothing deletes a store: resets and restores move files into `RecoveryBackup-*` / `PreRestoreBackup-*`, which `StoreBackupRestore` can bring back.
- `DataStoreRecoveryView` must never make a destructive action the primary one or promise that iCloud will restore data.

## Verification Notes

- Don't assume a simulator destination exists — resolve one first with `xcrun simctl list devices available` and pass it as `-destination "id=<UUID>"`. As of 2026-07, the installed runtimes are iOS 18.x and 26.5 (no 17.x); named-device + `OS:latest` lookups have failed on this machine before.
- The paywall loads live StoreKit products from `Pawtrackr.storekit` — both shared schemes reference it in their LaunchAction. If `Product.products` returns nothing in a dev build, check that scheme reference before suspecting code.

## Live Presentation and Digital Workflows

- Actor commits must refresh the visible model graph, including pet behavior, current sessions, relationships, and loyalty. Fetching IDs into an already-materialized context is not proof of freshness. Use a retained fresh presentation context after committed changes; keep unsaved edits intact and never mirror a background save onto stale models merely to trigger observation.
- Mutations broadcast the existing local events. Dashboard and Insights retain a pending refresh when a change arrives during an in-flight refresh.
- Keep the client-level aggressive banner and the pet safety badge. Do not duplicate the aggressive warning as an emoji pill. Behavior auras supplement readable labels, never replace safety warnings, and stop under Reduce Motion, backgrounding, low power, or thermal pressure.
- Aggression clears only after three completed, explicitly observed non-aggressive visits: calm, cooperative, anxious, or nervous, in any combination. An aggressive visit resets the counter immediately. Untagged and special-needs-only visits do not advance or break the counter. Never preselect a previous temperament on a new checkout.
- Special needs is a standing priority-care flag, separate from temperament. Checkout must preserve it until explicitly edited on the profile. Display both warnings when aggression and special needs coexist. Card glow precedence is aggression/red, special needs/purple, anxious/orange, nervous/blue, calm-or-cooperative/green. Chips and checkout choices use the same semantic colors; after clearance, display the latest observation rather than accumulating old moods.
- Pawtrackr is digital-only: no Bluetooth printer discovery, thermal receipt transmission, cash-drawer integration, or peripheral permissions. Keep digital PDF receipts, sharing, and exports. The subscription system remains paused; do not introduce subscriptions.
