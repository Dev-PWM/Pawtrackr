# Behavior handling and client UX — October 12, 2026

## User decision

Keep the existing client warning and pet badge positions. A pet carrying an aggressive handling warning must complete three visits explicitly recorded as calm, cooperative, anxious, or nervous before the warning clears. These observations may be mixed. Any completed aggressive visit immediately restores the warning and resets the count. Do not interpret an anxious or nervous observation as permission to handle carelessly; the three-visit rule is the user's operational policy, not a veterinary safety guarantee.

Special needs remains an independent, persistent priority-care flag. It must not disappear when temperament changes or aggression clears. This change does not add an automatic expiry or a new care-removal control. Do not automatically infer care requirements from estimated age or birthday data.

## Presentation

| State | Card glow | Readable cue |
| --- | --- | --- |
| Aggressive warning active | Red | Existing client caution banner and pet warning badge; completed-visit progress when applicable |
| Special needs | Purple | Client priority-care banner and pet priority badge; both warnings coexist if aggressive |
| Anxious | Orange | Anxious emoji chip, no temperament warning banner |
| Nervous | Blue | Nervous emoji chip, no temperament warning banner |
| Calm / cooperative | Green | Calm / cooperative emoji chips, no temperament warning banner |

Aura precedence: aggression, special needs, anxious, nervous, cooperative, calm. Safety/care takes precedence while a warning is active; the latest temperament remains readable as a chip. The existing design tokens supply the colors, through one shared resolver. Glow is supplemental, decorative, and non-interactive; readable labels remain available with Reduce Motion and without color perception.

## Corrections

- Anxious cards no longer incorrectly share nervous blue; special-needs cards no longer incorrectly use anxious amber.
- Both model reconciliation and the displayed counter accept all four approved non-aggressive observations.
- Clearance uses only the latest recorded mood. Earlier calm/cooperative observations no longer manufacture a green tag on a currently nervous pet.
- Calm/cooperative remain visible during probation rather than being silently removed from the pet profile.
- Standing special needs survives every checkout and aggressive relapse. Care-only and untagged visits preserve the last temperament and do not count as new evidence.
- Fresh checkout sessions do not inherit previous aggression, anxiety, nervousness, or calmness as today's observation. Care tags can be preselected independently.
- Aggressive and non-aggressive selections are mutually exclusive. Calm/cooperative can coexist; anxious/nervous selections replace conflicting non-aggressive moods. Special needs can coexist with any observation.
- Checkout feedback keeps the standing warning red until a successful checkout commits the change. The third qualifying visit does not prematurely announce a green Calm badge when the actual observation is anxious/nervous or priority care remains.
- Client lists, client details, pet details, and compact pet cards show independent special-needs priority cues. English and both Spanish localizations and Academy guidance use the corrected terminology.

## Verification scope

Actor-backed regression tests cover mixed and Spanish observations, preservation of care, relapse, care-only/untagged visits, contradictory imported aggression, and fresh checkout selection. Color tests verify all six shared mappings. UI automation uses only isolated in-memory test data and checks client refresh across checkouts without leaving/reopening the client screen. No model schema or migration plan was added.

Final test outcomes and visual evidence are appended after verification. The live checkout test revealed that a refreshed client banner could coexist with a stale pet card: fresh SwiftData objects have the same persistent identifiers, and ForEach could retain the previous graph's display closures. A per-card handling key alone did not fix successive refreshes. The view model now publishes a presentation revision whenever it successfully replaces its model graph, and the pet-list display uses that revision as an identity boundary. This resets display-only content without resetting the checkout view model or other editors. Tests explicitly compare client-banner and pet-badge progress and check the latest chip after each visit.
