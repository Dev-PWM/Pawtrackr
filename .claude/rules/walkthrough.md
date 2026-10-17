---
paths:
  - "Pawtrackr/Features/Walkthrough/**"
---

# Walkthrough Rules

- `PracticeSalon` is the Academy sandbox: an in-memory container (`isStoredInMemoryOnly: true`) the main window runs on while the tour is open. It never touches the store on disk. Keep every leak guard listed in its header comment:
  - it is registered with `SpotlightIndexer` before seeding, so none of its records are indexed;
  - example prices live in their own `UserDefaults` suite (`com.pawtrackr.practiceSalon`), cleared on open and on close;
  - views check `EnvironmentValues.isPracticeSalon` before advertising a client over Handoff or retiring the Getting Started checklist;
  - tour checkouts run in the walkthrough preview, which never writes a checkout draft.
- `WalkthroughOverlay` on compact iPhone (`WalkthroughCompactUITests`): the bubble is clamped to safe bounds with 16 pt margins and placed above or below the target by available headroom after safe-area insets (Dynamic Island, home indicator). The dim cutout is an even-odd fill; don't replace it with blend modes.
- Emit `.walkthroughAnchor` from a detached `.background` so nested anchors with the same key merge instead of being clobbered to nil.
- `.environment` objects don't reach `.sheet` / `.fullScreenCover` content. Re-inject them at the presentation site, or the in-modal walkthrough overlay silently does nothing.
