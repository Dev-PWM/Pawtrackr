# Pawtrackr Agent Guide

Shared by Codex and Claude Code (`CLAUDE.md` imports this file). App-wide UI conventions are in `Pawtrackr/AGENTS.md`. Subsystem rules are in `.claude/rules/*.md`, each scoped by `paths:` so Claude Code loads it only when matching files are touched. Other agents: before editing storage, checkout, clients, loyalty, walkthrough, or pet-behavior code, read the matching `.claude/rules/<area>.md` (`storage`, `checkout`, `clients`, `loyalty`, `walkthrough`, `pet-behavior`).

Don't add more docs under `Pawtrackr/`. It is an Xcode synchronized folder, so every file there is copied into the app bundle; the existing `Pawtrackr/AGENTS.md` currently ships inside the built app.

## Invariants

1. **Local-only persistence (ADR-0005).** Every `ModelConfiguration` sets `cloudKitDatabase: .none`, and every `ModelContainer` passes `configurations:`. No `import CloudKit`, `NSUbiquitous*`, CK containers or sync engines, or remote-push registration and entitlements; `ci_scripts/validate_local_persistence.py` fails CI on any of them. Legacy device/presence models stay only for store compatibility; don't restore cloud UI, permissions, sync engines, or ubiquitous settings.
2. **No migration plan; schema changes are additive (ADR-0003, ADR-0004).** `SchemaMigrationPlan`, `migrationPlan:`, and unique constraints (`@Attribute(.unique)`, `#Unique`) on store models fail `ci_scripts/ci_pre_xcodebuild.sh`. 1.0.2 shipped a staged plan built from live model classes; every 1.0.1 store failed with `NSCocoaErrorDomain 134504` and users reset their clients away. Add models, optional or defaulted properties, and `@Attribute(originalName:)` renames only. Each release adds its store to `PawtrackrTests/Fixtures` (see `StoreFixtures.md`), and `StoreUpgradeRegressionTests` must open all of them.
3. **The main thread is for UI.** Database writes run in `@ModelActor`s (`ClientRepository`, `CheckoutTransactionActor`, `InsightsActor`) or short-lived background `ModelContext`s. Commits reach `@MainActor` through `LocalStoreCommitBridge` (`ModelContext.didSave`) and `GlobalEventBus`, with no restart. Fetching IDs into an already-materialized context is not proof of freshness: after a commit, use a retained fresh presentation context, keep unsaved edits intact, and never mirror a background save onto stale models just to trigger observation. Dashboard and Insights keep a pending refresh when a change arrives mid-refresh.
4. **`Decimal` only** for money and pet weight, never `Double` or `Float`.
5. **No Codable enums stored on `@Model`s.** A composite attribute crashes `@Query` on an unknown raw value. Store a raw `String` (`speciesRaw`, `genderRaw`, `behaviorTagsRaw`) and expose a `@Transient` computed enum with a safe fallback.
6. **Platform isolation.** iPhone-specific layouts and Academy walkthrough adjustments are gated by `#if os(iOS)` and `horizontalSizeClass == .compact`. Don't alter or regress macOS layouts: `DetachedClientWindow`, `DetachedInsightsWindow`, `MenuBarExtra`, the 3-column desktop grids, or window frame budgets.
7. **Logging and retain cycles.** No `print()`; use the `Logger` categories in `Pawtrackr/Core/Services/Logging.swift` (`.ui`, `.database`, `.performance`, `.network`, `.security`, `.dataIntegrity`, …) or a feature logger such as `.checkout`. Capture `[weak self]` in tasks that loop over `eventBus.stream` or `observeChanges` (`MemorySafetyTests`).

## Store Safety

- Nothing deletes a store. Store-file work (scheduled restore, per-build backup, legacy move) runs only in `PawtrackrApp.init`, before any container opens. Resets and restores move `.store`, `-wal` and `-shm` files into `RecoveryBackup-*`, `PreRestoreBackup-*` or `PreMigrationBackup-*`, which `StoreBackupRestore` can bring back.
- `DataStoreRecoveryView` must never make a destructive action the primary one or promise that iCloud will restore data.
- Before shipping, install the previous App Store build, add data, then install the new build over it without deleting.

## Product Constraints

- Digital-only: no Bluetooth printer discovery, thermal receipts, cash drawers, or peripheral permissions. Keep PDF receipts, sharing, and exports.
- The subscription system is paused; don't introduce subscriptions.

## Verification Notes

- Don't assume a simulator destination exists. Resolve one with `xcrun simctl list devices available` and pass `-destination "id=<UUID>"`. As of 2026-07 the installed runtimes are iOS 18.x and 26.5 (no 17.x); named-device + `OS:latest` lookups have failed on this machine.
- The only shared scheme is `Pawtrackr`. Its `TestPlan.xctestplan` holds `PawtrackrTests` and `PawtrackrUITests`; narrow a run with `-only-testing:`.
- The paywall loads StoreKit products from `Pawtrackr.storekit`. As of 2026-10-16 the shared scheme's LaunchAction does not reference it, so if `Product.products` returns nothing in a dev build, set the scheme's StoreKit Configuration before suspecting code.
