# Pawtrackr App Conventions

The root `AGENTS.md` covers persistence, `Decimal`, threading and logging. These add app-wide conventions.

## Data

- Multi-model operations such as checkout are atomic; no intermediate states are saved.
- Saving edits from another local context preserves unrelated fields.
- Log local persistence failures with `.error` and surface the failed operation in the UI.
- If local storage fails to open, show recovery with the preserved backups. Never delete the store or promise remote recovery.
- `DataPruningService` clears temporary assets older than 30 days; historical visit photos are kept unless `DataPruner` is called with `pruneStoredPhotos: true`.

## UI

- Buttons use `pressScaleStyle()`.
- Every interactive element has an `accessibilityLabel`. Support Dynamic Type with flexible stacks.
- Insights and revenue screens use `.privacyBlur()` to hide business data in the background.
- Prefer Apple frameworks (Charts, PhotosUI) over custom utility code.

## Code

- New utility functions get DocC comments.
