---
paths:
  - "Pawtrackr/Core/Storage/**"
  - "Pawtrackr/App/PawtrackrApp.swift"
---

# Storage Rules

- `DataStoreService` is the central SwiftData facade. The production initializer takes the existing `ModelContainer`; tests and QualityControl use the `inMemory` initializer.
- Background fetches create a detached `ModelContext` from the shared `ModelContainer`; UI-bound fetches stay on the main actor.
- Never delete `.store`, `-wal` or `-shm` files; rotate them into `RecoveryBackup-*`, `PreMigrationBackup-*` or `PreRestoreBackup-*` (see the root `AGENTS.md`).
- Pre-boot store-file work takes `StoreFileLockCoordinator` first: `open(O_CREAT)` + `flock` on `Pawtrackr.store.lock`, so every thread and process locks the same inode. Don't swap in `FileManager.createFile`, which can replace the file and give later callers a different inode.
- `DataSafetyMonitor` locks Start Fresh when the live client count drops to zero after real data existed. Sample clients (fixed UUIDs in `SampleData`) never count toward that baseline.
- `SummaryUpdater` writes `DaySummary`, `ServiceDaySummary`, `CategoryDaySummary` and `ClientInsightSummary` rows only through its equality-checking `assign` helper; assigning an equal value still dirties the row and triggers save/refresh churn. Keep the `relationshipKeyPathsForPrefetching` on visit items, pets and visits to avoid N+1 faults.
- Images go through `LocalMediaPolicy` (full size capped at 1600 px, thumbnails 240 px with optimization on, 300 px otherwise) and are stored with `@Attribute(.externalStorage)`. `DataPruner` keeps historical visit photos unless a caller passes `pruneStoredPhotos: true`; `DataPruningService` only clears temporary assets older than 30 days.
- `Models/Pet.swift` behavior and aggression rules are in `.claude/rules/pet-behavior.md`.
