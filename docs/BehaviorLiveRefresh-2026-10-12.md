# Behavior presentation and live refresh — 2026-10-12

The three-visit safety algorithm remains the source of truth. The regression was in presentation: opening a client reused a cached navigation graph, and the background history query resolved committed visit IDs through an old main-actor context. Completed visits could therefore appear to revert to Processing, and an old aggressive profile could return after navigation.

## Changes

- Client detail opens and reappears with a fresh retained presentation graph when there are no unsaved edits. Existing unsaved editor graphs remain intact.
- History resolves background query results through an independent fresh retained context, with autosave disabled. It stays current even while profile edits are unsaved; it does not copy committed values onto stale models.
- Existing checkout notifications still refresh the client immediately. Fetch cancellation guards prevent old history tasks from overwriting a newer refresh.
- Pet lookups and check-in App Intents read a new context for each invocation, avoiding cached pre-checkout sessions.
- Client timelines, pet history and visit detail share labeled semantic behavior chips. Aggressive historical observations retain a red border and warning symbol after current clearance. History labels expose the observed behaviors to accessibility.
- Anxious uses adaptive teal (#0F766E light, #5EEAD4 dark), distinct from amber operational warnings. Calm/cooperative remain green, nervous blue, special needs purple and aggression red. Readable names accompany every color.

## Safety contract

An aggressive completed observation activates the warning and resets progress to zero. The warning and red card remain through the first two explicitly observed non-aggressive completed visits. Calm, cooperative, anxious and nervous qualify in any combination. The third qualifying checkout removes the current warning and uses that visit's observation. Any later aggressive visit starts the cycle again. Untagged and care-only visits neither advance nor break progress. Special needs remains an independent standing care flag; it retains purple card priority after aggression clears. Historical visit observations are never rewritten by current clearance.

## Verification

Focused unit coverage includes mixed observations, relapse/reset, localized tags, untagged/care-only visits, historical observations surviving clearance, stale graph reopening after the third qualifying checkout, unsaved edits, client list/history refresh and App Intents. The simulator UI flow completes Calm → Anxious → Nervous, leaves and reopens the client after every checkout, verifies clearance and care, then completes an aggressive relapse. Native macOS inspection confirms Milo remains Calm/green with completed Paid history after reopening and shows older aggressive history in red.

Validation passed: 56 focused unit tests, 2 simulator UI tests (the full clearance/reopen/relapse flow and the true light/dark anxious appearance comparison), the macOS build-and-launch verification, and CodeRabbit review with zero findings. Appearance captures were inspected after applying Pawtrackr's own `preferredColorScheme` preference; the simulator appearance flag alone was overridden by the saved app preference.

No store schema, migration, cloud persistence or historical loyalty values change.
