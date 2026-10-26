# Pawtrackr Agent Guide

Shared by Codex and Claude Code. `Pawtrackr/AGENTS.md` adds app conventions; nested `AGENTS.md` files own storage, clients, checkout, walkthrough and theme rules. Before editing cross-cutting code or tests, read the matching `.claude/rules/{storage,clients,checkout,loyalty,walkthrough,pet-behavior,theme}.md` and any guide it points to.

Exclude agent docs under `Pawtrackr/` from the synchronized app target in `Pawtrackr.xcodeproj/project.pbxproj`; never ship instructions as resources. The same exception set keeps `GoldenRecord.json` (a schema note no code reads) out of the bundle. Keep reports outside app source. Canonical repository skills live in `.claude/skills/`. `.gitignore` excludes retired mirrors, history dumps and build logs from ordinary searches; it is not an access-control or universal context-indexing mechanism.

## Invariants

1. **Local-only persistence (ADR-0005).** Every `ModelConfiguration` sets `cloudKitDatabase: .none`, and every `ModelContainer` passes `configurations:`. No `import CloudKit`, `NSUbiquitous*`, CK containers or sync engines, or remote-push registration and entitlements; `ci_scripts/validate_local_persistence.py` fails CI on any of them. Legacy device/presence models stay only for store compatibility; don't restore cloud UI, permissions, sync engines, or ubiquitous settings.
2. **No migration plan; schema changes are additive (ADR-0003, ADR-0004).** `SchemaMigrationPlan`, `migrationPlan:`, and unique constraints (`@Attribute(.unique)`, `#Unique`) on store models fail `ci_scripts/ci_pre_xcodebuild.sh`. 1.0.2 shipped a staged plan built from live model classes; every 1.0.1 store failed with `NSCocoaErrorDomain 134504` and users reset their clients away. Add models, optional or defaulted properties, and `@Attribute(originalName:)` renames only. Each release adds its store to `PawtrackrTests/Fixtures` (see `StoreFixtures.md`), and `StoreUpgradeRegressionTests` must open all of them.
3. **The main thread is for UI.** Database writes run in `@ModelActor`s (`ClientRepository`, `CheckoutTransactionActor`, `InsightsActor`) or short-lived background `ModelContext`s. Commits reach `@MainActor` through `LocalStoreCommitBridge` (`ModelContext.didSave`) and `GlobalEventBus`, with no restart. Fetching IDs into an already-materialized context is not proof of freshness: after a commit, use a retained fresh presentation context, keep unsaved edits intact, and never mirror a background save onto stale models just to trigger observation. Dashboard and Insights keep a pending refresh when a change arrives mid-refresh.
4. **`Decimal` only** for money and pet weight, never `Double` or `Float`.
5. **No Codable enums stored on `@Model`s.** A composite attribute crashes `@Query` on an unknown raw value. Store a raw `String` (`speciesRaw`, `genderRaw`, `behaviorTagsRaw`) and expose a `@Transient` computed enum with a safe fallback.
6. **Platform isolation.** iPhone-specific layouts and Academy walkthrough adjustments are gated by `#if os(iOS)` and `horizontalSizeClass == .compact`. Don't alter or regress macOS layouts: `DetachedClientWindow`, `DetachedInsightsWindow`, `MenuBarExtra`, the 3-column desktop grids, or window frame budgets.
7. **Logging and retain cycles.** No `print()`; use the `Logger` categories in `Pawtrackr/Core/Services/Logging.swift` (`.ui`, `.database`, `.performance`, `.network`, `.security`, `.dataIntegrity`, …) or a feature logger such as `.checkout`. Capture `[weak self]` in tasks that loop over `eventBus.stream` or `observeChanges` (`MemorySafetyTests`).

## Product Constraints

- Digital-only: no Bluetooth printer discovery, thermal receipts, cash drawers, or peripheral permissions. Keep PDF receipts, sharing, and exports.
- The subscription system is paused; don't introduce subscriptions.

## Verification Notes

- Don't assume a simulator destination exists. Resolve one with `xcrun simctl list devices available` and pass `-destination "id=<UUID>"`. Resolve current device UUIDs at runtime; named-device + `OS:latest` lookups have failed on this machine.
- The only shared scheme is `Pawtrackr`. Its `TestPlan.xctestplan` holds `PawtrackrTests` and `PawtrackrUITests`; narrow a run with `-only-testing:`.
- The paywall loads StoreKit products from `Pawtrackr.storekit`; the shared scheme's LaunchAction references it (`StoreKitConfigurationFileReference`, restored 2026-10-16 after it was dropped in September). If `Product.products` returns nothing in a dev build, check that reference before suspecting code.
