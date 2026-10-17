# Pawtrackr Architecture Guide

## Overview
Pawtrackr is a business management app for pet professionals, built with **SwiftUI** and **SwiftData** in an **MVVM-R (Model-View-ViewModel-Repository)** architecture. Data stays on the device (ADR-0005).

## Core Pillars

### 1. Data Persistence (local SwiftData)
- **Local only:** Every store is configured with `cloudKitDatabase: .none`; `ci_scripts/validate_local_persistence.py` fails CI on CloudKit, ubiquitous storage, or remote push. Legacy device/presence models remain only so shipped stores keep opening.
- **Upgrades:** No `SchemaMigrationPlan` (ADR-0004). Schema changes are additive and checked by `StoreUpgradeRegressionTests` against every shipped store in `PawtrackrTests/Fixtures`.
- **Live refresh:** `LocalStoreCommitBridge` observes `ModelContext.didSave` and broadcasts through `GlobalEventBus`, so commits from background actors update visible screens without a restart.
- **Models:** Use the `@Model` macro. Non-sendable model objects never cross actor boundaries.

### 2. The Repository Pattern (MVVM-R)
- **Repositories:** The interface between view models and the database.
- **Background actors:** Most repositories (e.g. `ClientRepository`) are `@ModelActor` implementations. They fetch on background threads and return **PersistentIdentifiers** or **Sendable** values, keeping the main thread responsive with 10,000+ records.

### 3. Concurrency Strategy (Swift 6)
- **Strict concurrency:** The project uses Swift 6 strict mode.
- **Data handoff:** View models fetch IDs from background repositories and resolve them to models on the `@MainActor`.
- **Atomic transactions:** Critical operations such as checkout use dedicated actors (`CheckoutTransactionActor`) for idempotency and integrity.

### 4. Technical Reliability
- **Store health:** `StoreHealthCheck` verifies database integrity at launch.
- **Recovery:** Resets and restores move store files into backup folders instead of deleting them; `StoreBackupRestore` can bring them back.
- **Chaos testing:** `OmniChaosTests` simulate system failures.

## Key Utilities
- **`SearchEngine`:** Diacritic-insensitive filtering.
- **`SummaryUpdater`:** Background aggregation of revenue and KPI data.

## Engineering Mandates
1. **Always use `Decimal` for money.** Never use `Double` for financial totals.
2. **Inject repositories into view models** to make mocking and unit testing possible.
3. **Use PersistentIdentifiers** for navigation and cross-thread handoff.
