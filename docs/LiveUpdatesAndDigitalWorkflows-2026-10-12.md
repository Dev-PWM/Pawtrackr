# Pawtrackr live updates and digital workflows — October 12, 2026

## Implemented behavior

Client lists, client details, pet details, history and checkout completion now retain fresh presentation contexts when reading committed changes. This avoids resolving identifiers back into stale materialized model graphs. Client-detail refresh leaves a context with unsaved edits intact. Pet add/edit sheets publish committed changes without mirroring actor results onto stale objects and marking them dirty again. Contact saves notify the existing local update channel. An editor that survives a presentation refresh resolves the contact by UUID in the current context and applies only changed fields, preserving unrelated concurrent changes. Actions use the displayed model's owning context where required.

Dashboard retains a pending refresh instead of dropping changes during a refresh. Insights consumes client, visit and service notifications and starts a fresh analytics actor for refreshed reads. Existing visit-start/completion broadcasts continue to connect normal UI and AppIntent check-ins.

The reward chooser observes `CheckoutViewModel` directly. Choices remain reversible until confirmation, and the chooser uses live points, catalog and subtotal values. Selection closes through its view-model presentation state. Loading, empty catalog and retry states remain visible. Actor-side catalog/balance/expected-total validation, Decimal arithmetic, atomic persistence and visit-keyed idempotency remain authoritative. No fixed points-to-currency conversion was introduced; existing salon rewards determine the credit.

The client-level aggressive banner and pet safety badge remain. Supplemental grooming chips omit the duplicate aggressive emoji pill, while other behavior labels stay readable. Following the user's behavior correction, pet cards use green/calm-or-cooperative, orange/anxious, blue/nervous, red/aggressive or purple/priority-special-needs auras. The decorative overlay does not intercept actions or walkthrough highlights. Animation is gated by scene activity, Reduce Motion, low-power mode and thermal state. New pet and client list changes have short transitions rather than requiring an app restart. The corrected clearance and independent care rules are documented in `docs/BehaviorHandlingUX-2026-10-12.md`.

Birthday and honorary celebration banners can be tapped to replay a finite confetti cue. Existing calendar anniversary logic, age estimates and safety rules remain intact. The Academy explains current profile fields, behavior cues, birthdays and redemption at the Payment step in English and Spanish. Its card-width clamp fits narrow viewports. UI test navigation now recognizes both iPhone tabs and iPad sidebar rows.

Bluetooth printer discovery, peripheral management, ESC/POS receipt transmission and cash-drawer commands were removed, along with their implementation-specific tests. Bluetooth, USB and printing capability declarations were removed. Digital PDF receipts, sharing, exports and pet photo capture remain. The subscription system remains paused.

## Verification evidence

| Check | Result |
| --- | --- |
| Focused checkout, behavior, client, milestone and walkthrough tests | 167 passed |
| Full unit suite after core implementation | 690 passed, zero failures |
| Final walkthrough and localization checks after copy updates | 89 passed, zero failures |
| Final contact/client-detail checks, including an editor surviving refresh | 30 passed, zero failures |
| iPhone client details, loyalty and Academy UI workflows | 8 passed |
| iPad client opening, reward-credit checkout and Academy UI workflows | 3 passed after sidebar-aware test helper correction |
| Native macOS build | Passed |
| CodeRabbit implementation review | One minor Spanish VoiceOver progress wording issue, corrected |
| Property-list/string validation and Git whitespace check | Passed |

The initial iPad run failed because the test helper required an iPhone tab bar. The corrected helper uses the existing sidebar identifiers when present. The iPhone UI MCP call reached its 300-second timeout just as Xcode completed; the Xcode log and result bundle independently confirm all eight selected tests passed.

The final copy checks initially rejected long guide text and semicolons. The explanation was split into a short directive and bounded coach tip. The last 89-test run passed without loosening the assertions.

## Performance and memory evidence

One ETTrace v1.1.0 launch capture used a temporarily linked simulator framework, UUID-matched app/framework dSYMs, an iPhone 18 Pro on iOS 27.0, and the in-memory UI-test Client Center fixture. The flow was launch to a stable client-list render. The processed trace contains 11.499 seconds total, 9.805 seconds idle and 1.695 seconds active sampling weight. Inclusive app initialization is 0.278 seconds, store bootstrap is 0.170 seconds and UI-test seeding is 0.108 seconds. These are overlapping sampled stack weights, not independent elapsed durations or before/after improvements. System-framework symbolication was limited in this simulator runtime. This launch capture does not establish animation frame rate or a zero-frame-drop guarantee.

Processed trace: `/tmp/pawtrackr-ettrace.XGhATq/launch-profile/output_259.json`.

A regular, uninstrumented seeded Client Center memory snapshot reported 28 unattributed malloc allocations totaling 896 bytes and a 53.8 MB peak physical footprint. No app-owned leaked type or retaining edge was identified. This idle capture does not prove every view-release path leak-free, and no leak fix is claimed.

Memory graph: `/tmp/pawtrackr-live-memory/PartnerShipWithMedia.Pawtrackr-63384-20261012-034051.memgraph`.

Memory summary: `/tmp/pawtrackr-live-memory/leak-summary.md`.

The regular build was reinstalled after profiling. The repository project, schemes and release build settings contain no ETTrace wiring. Profiling artifacts are temporary and can be removed by OS cleanup.

## Review limitations

The explicitly requested security diff workflow inspected its immutable source-like changed-file inventory, including existing user edits and deleted-file baselines. Its report finalization was unsuccessful: the submitted coverage surface shape was rejected, and completion returned **“The latest saved scan draft is incomplete; continue the scan before completing it.”** The durable scan remains unsealed under scan ID `5119a44f-d061-4ce4-8c0f-40bf170a3990`. Do not treat it as a completed security report or a security clearance. Later Academy/test-helper changes and USB/print permission removals occurred after that saved snapshot. No original security vulnerability was supplied for the separate verify-fix workflow.

Builds and simulator checks support the requested workflows. They do not replace a physical-device upgrade test with the previous App Store build and retained salon data. Existing model/schema compatibility and local store recovery policies remain in force.
