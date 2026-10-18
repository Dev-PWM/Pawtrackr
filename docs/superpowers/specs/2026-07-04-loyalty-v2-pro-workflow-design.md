# Loyalty V2 and Mac/iPad Pro Workflow Design

> Historical record. ADR-0003/0004 supersede the staged-migration examples, ADR-0005 supersedes CloudKit guidance, and subscriptions are paused. Current implementation rules are in root `AGENTS.md` and scoped subsystem guides.

## Context

Pawtrackr already has StoreKit-backed subscription gating, client-owned loyalty points, a
schema-free built-in rewards catalog, `LoyaltyLedgerEntry` audit rows, SwiftData migration
scaffolding, `NavigationSplitView`, a macOS `WindowGroup`, a menu bar extra, and Swift Charts
selection in dashboard analytics.

The upgrade notes point toward two next product pillars:

- **Loyalty V2:** configurable earning rules and owner-editable rewards.
- **Mac/iPad Pro Workflow:** detached work surfaces, richer menu/window actions, and more useful
  analytical scrubbing.

These belong in one roadmap because the Mac/iPad workflow should consume the same loyalty and
analytics data model. They should still ship in phases because Loyalty V2 changes durable
CloudKit-backed schema and must be proven before richer UI surfaces depend on it.

## Goals

- Keep loyalty points owned by `Client`, preserving the existing checkout and ledger model.
- Add a CloudKit-safe persistent loyalty configuration model.
- Add a CloudKit-safe persistent rewards catalog that replaces the current hardcoded display
  catalog over time.
- Preserve today's default earning behavior unless the owner changes settings.
- Support a flat earning mode for the desired "20 points per visit, 100 point reward" setup.
- Add a V2 SwiftData schema and migration stage for structural loyalty changes.
- Build Mac/iPad pro surfaces on top of the stable Loyalty V2 data layer.
- Prefer SwiftUI-native window, navigation, chart, toolbar, and menu APIs.
- Use AppKit only for narrow macOS gaps such as window focus behavior that SwiftUI cannot express.

## Non-Goals

- Do not move loyalty points from `Client` to `Pet`.
- Do not add a client-side companion app.
- Do not introduce `@Attribute(.unique)` to new SwiftData models.
- Do not hand-roll a non-StoreKit trial or entitlement system.
- Do not implement local mesh register sync in this phase.
- Do not add Cloudflare Agents or remote MCP infrastructure for this local-first feature.
- Do not rewrite the main navigation architecture.

## Approach

Plan as one roadmap with two implementation phases.

### Phase 1: Loyalty V2 Data Foundation

Loyalty V2 owns the durable schema and business rules. It must land first because it changes the
SwiftData/CloudKit model surface.

The current client-owned loyalty structure stays intact:

- `Client.loyaltyPoints` remains the current balance.
- `Visit.loyaltyPointsChange` remains the idempotency anchor for checkout earning.
- `LoyaltyLedgerEntry` remains the audit trail for earns, redemptions, and adjustments.
- `LoyaltyCheckoutProcessor` remains the single checkout earning path.
- `LoyaltyService` remains the background actor for loyalty mutations.

Additive models:

- `LoyaltyConfig`
  - business-level singleton seeded by startup maintenance if missing
  - earn mode: points per dollar or flat points per visit
  - `pointsPerDollar: Decimal`, default `1`
  - `pointsPerVisit: Int`, default `20`
  - `redemptionThreshold: Int`, default `100`
  - `isRewardsCatalogEnabled: Bool`, default `true`
- `LoyaltyRewardTemplate`
  - owner-editable reward title, detail, point cost, symbol/style metadata, and enabled state
  - seeded from the existing built-in catalog
  - no required relationship to `Client`

The existing `LoyaltyReward` struct becomes a display DTO or seed definition. It should not be the
long-term source of truth once the persistent catalog exists. The first V2 UI exposes both earning
modes immediately so the owner can choose today's default `1 point / $1` behavior or the desired
`20 points / visit` behavior without another schema change.

### Phase 2: Mac/iPad Pro Workflow

After Loyalty V2 is stable, build the pro workflow surfaces that consume it.

SwiftUI-native surfaces:

- detached client detail windows for iPad/macOS where supported
- detached loyalty/rewards windows for focused client retention work
- insights windows for back-office analysis
- toolbar, context menu, and menu bar actions that open focused surfaces via SwiftUI `openWindow`
- richer insight scrubbers using existing Swift Charts selection patterns

The main `NavigationRouter` remains the owner of the main app window. Detached windows resolve their
own model from `modelContext` using route values such as a client UUID. A detached window should be
able to close, reload, or show a missing-record state without mutating global navigation.

## Data Flow

### Loyalty Earning

1. Checkout completes through the existing checkout transaction path.
2. `LoyaltyCheckoutProcessor` receives the visit, pet, total, and a loyalty config snapshot.
3. The processor computes earned points using `Decimal` money inputs and integer point outputs.
4. The processor writes `Visit.loyaltyPointsChange` and delta-adjusts `Client.loyaltyPoints`.
5. The processor upserts one earned `LoyaltyLedgerEntry` per visit UUID.
6. The caller owns the SwiftData save boundary and CloudKit change recording.

Default behavior must match today: `1 point / whole $1` with existing tier and rebook bonus logic.
Flat mode supports the desired `20 points / visit` behavior. A `100` point reward threshold is a
configuration default and seed catalog cost, not a second hardcoded point owner.

### Loyalty Management

1. A loyalty settings view loads a sendable config/reward snapshot from `LoyaltyService`.
2. Edits validate on the main actor before calling the background service.
3. `LoyaltyService` mutates `LoyaltyConfig` and `LoyaltyRewardTemplate` inside its `ModelActor`.
4. UI refreshes through existing SwiftData observation and event-bus patterns.

Manual adjustments and redemptions remain in `LoyaltyService`, which already prevents overdrafts and
writes ledger rows.

### Pro Windows

1. Main-window UI, menu bar, or toolbar action asks SwiftUI to open a typed route.
2. The detached scene receives a route value, usually a UUID.
3. The scene resolves the model from its own `modelContext`.
4. Missing or deleted models render a clear unavailable state.
5. Edits go through existing services and model actors, not through duplicate detached-window state.

### Insights Scrubbing

Insights scrubbers should work from view-model DTOs or aggregate rows already loaded by
`InsightsViewModel`/`DashboardViewModel`. Chart hover or selection must not trigger body-time
database fetches.

## UI Design

### Loyalty V2

Add a premium loyalty management surface with:

- earning mode segmented control: points per dollar or flat points per visit
- Decimal input for points per dollar
- integer input/stepper for points per visit
- integer reward threshold/default cost controls
- rewards list with add/edit/disable/delete actions
- ledger preview for recent earns, redemptions, and adjustments

Existing client detail loyalty entry points should continue to work. Non-premium users should still
hit the existing subscription paywall. Premium users should see the configured rewards catalog
instead of the hardcoded catalog once Phase 1 is complete.

### Mac/iPad Pro Workflow

Add focused work surfaces:

- client detail in a detached window
- loyalty/rewards for a selected client in a detached window
- insights in a dedicated analysis window

The Mac UI should stay operational and information-dense. Avoid marketing-style panels. Prefer
toolbars, menus, stable split views, charts, tables, and compact controls.

Window entry points are:

- toolbar and context-menu actions for detached client and loyalty windows
- menu bar action for the main window
- macOS command/menu action for the dedicated insights window

## Error Handling

- If no `LoyaltyConfig` exists, startup maintenance creates one with safe defaults.
- Config values reject negative points, zero-or-negative reward costs, and invalid Decimal values.
- Reward redemption continues to reject overdrafts.
- Disabled rewards remain visible in admin/config views but cannot be redeemed.
- Missing detached-window models show a recoverable unavailable state.
- Migration failure uses the existing non-destructive recovery path; it must not recreate or wipe
  the store.
- CloudKit fallback remains local-only and user-visible through existing app mechanisms.

## Migration Design

Add `PawtrackrSchemaV2` and repoint `typealias PawtrackrSchema` to V2.

V2 includes all V1 models plus:

- `LoyaltyConfig`
- `LoyaltyRewardTemplate`

The V1-to-V2 stage is lightweight because the new models are additive and all fields are optional
or defaulted. Any future rename, type change, or required backfill must use a custom migration
stage.

CloudKit rules:

- no `@Attribute(.unique)` on new models
- default non-optional scalar values
- optional/defaulted relationships only
- deploy schema changes to CloudKit Production before App Store release

## Testing

### Loyalty V2 Tests

- V1-to-V2 migration opens an old store with clients, pets, visits, checkout transactions, and
  ledger entries still intact.
- Default config preserves existing `1 point / $1` checkout behavior.
- Flat mode awards `20 points / visit`.
- A `100` point reward is redeemable only when the client has enough balance.
- Redemption writes a negative ledger row and cannot overdraw.
- Reprocessing checkout remains idempotent by visit UUID.
- Config and reward mutations run through the background service without main-actor database saves.

### Mac/iPad Pro Workflow Tests

- Main-window client navigation still works.
- Supported platforms can open a detached client route.
- Missing detached client route shows unavailable state.
- Menu bar action opens/focuses the main window.
- Insights scrubber selection updates visible metrics without layout regressions.
- macOS build succeeds after window/menu changes.

### Verification Commands

- `git diff --check`
- focused loyalty unit tests
- focused UI tests for client/loyalty routes
- iOS simulator build/test using the installed simulator OS explicitly when needed
- macOS build for the `Pawtrackr` scheme

## Rollout

1. Land Loyalty V2 schema, service, and tests.
2. Run upgrade-path validation before any UI depends on the new models.
3. Deploy CloudKit schema changes to Production before TestFlight/App Store release.
4. Replace hardcoded rewards UI with persistent rewards.
5. Add detached windows and insights scrubbers.
6. Run CodeRabbit/security/review passes after implementation is complete.

## Implementation Decisions

- The first Loyalty V2 UI exposes both earning modes immediately.
- Detached iPad/macOS client and loyalty windows open from both toolbar and context-menu actions.
- macOS insights ships as a separate `WindowGroup` surface in Phase 2.
