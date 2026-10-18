# Client search diagnostic — October 17, 2026

## Dataset and isolation

The new deterministic fixture creates 1,000 distinct fictional owners and 1,000 dogs in a disposable, local-only, in-memory SwiftData container. Owner first names, surnames and dog names contain ASCII letters only; names have no numbered suffixes or punctuation. Examples include Ava Martinez, Adam Brown and Zoe Zimmerman, with dogs such as Luna, Milo, Willow and Toby.

The book contains 40 first names, 25 surnames, 20 dog names, 10 breeds, 500 female dogs and 500 male dogs. Profiles also contain synthetic phone numbers, test email addresses, birthdates, coat colors and Decimal weights. One hundred owners have active visits; 143 intentionally lack an emergency contact to exercise the smart filters.

`ClientSearchStressFixture.seed` refuses disk-backed configurations and writes on a background context. The fixture and its UI launch switch compile only in Debug. UI automation additionally requires `AppRuntime.isUITesting` and `PAWTRACKR_UI_SEARCH_STRESS=1`; ordinary launches cannot seed this book. No real client store was used or modified.

## Reproduced faults and fixes

| Fault reproduced before the fix | Result after the fix |
| --- | --- |
| Typing an explicit country code as `1 (202)` or `1 202 555` returned no clients while the number was incomplete. | Recognizes separated or punctuated NANP country prefixes while preserving ordinary digit substrings. |
| A full phone followed by an extension stopped matching if owner words followed the extension, such as `2025550018 ext 42 Ava`. | Removes extensions from complete phone expressions anywhere in an unscoped or phone-scoped query; following name terms remain required. Also accepts a comma before the extension. |
| An old Ava response could replace the visible list after typing changed to Zoe but before the next debounce completed. | Changing search text immediately cancels obsolete refresh and pagination work. The existing cancellation checks prevent stale publication. |

The pre-fix phone regression failed five assertions. A controlled delayed repository separately reproduced the stale-publication failure: 25 obsolete Ava results replaced the thousand-client list during the Zoe typing delay. Both regressions pass after the fixes. Boundary checks also ensure that a written country code cannot make a nine-digit main number qualify as a complete phone for extension removal.

## Accuracy and live-update checks

- 7,000 principal lookup probes cover every owner: first/last order, reversed order, uppercase, owner plus dog, owner plus breed, complete digits and formatted country-code phones. An independently built word index supplies the expected result sets; assertions check every returned identity, not just the presence of one target.
- Shared first names, surnames, dogs, breeds, partial phones and negative queries are checked under all five sort options. Matching sets must remain independent of sort order, with no duplicate rows.
- All four smart filters are checked with both first-name and last-name sorting. Active/inactive membership and all/active/missing-information counts must match the fixture's known states.
- Additional phone probes check incomplete country prefixes, extensions before name terms, comma-separated extensions, wrong full numbers, and negative terms that must not be discarded.
- A real `NewClientViewModel` creation makes Clara Watson and her female Corgi Pepper appear in an already-open Pepper search through the commit bridge. Clearing the search restores all 1,001 owners without recreating the list.
- Twenty concurrent production-repository creations run alongside 30 search/sort/filter changes. The retained list reaches 1,020 unique owners, keeps all 100 active owners, preserves the selected search/filter/sort and leaves an unrelated unsaved note intact.
- Native iPhone UI automation searches both ends of the book, including Zoe Zimmerman and Toby beyond the first hundred rows, and checks complete/wrong phones and clearing back to 1,000 clients.

## Measured query latency

Measured on the iPhone 18 Pro iOS 27 Simulator, using a Debug build and the 1,000-owner fixture:

| Measurement | Time |
| --- | ---: |
| Median lookup | 2.740 ms |
| 95th percentile lookup | 2.995 ms |
| Slowest lookup, including the cold cache | 198.470 ms |

These are repository lookup timings, including the actor hop. They exclude fixture creation, expected-result calculations, the existing 300 ms typing debounce and screen rendering. They characterize this Simulator run rather than physical-device or disk-store performance.

## Verification

- All 50 selected unit/integration tests passed: `ClientSearchStressTests`, `ClientSearchPrecisionTests`, `ClientManagementRegressionTests`, `ClientsViewModelListTests`, `LocalStoreCommitBridgeTests` and `PhoneUtilsTests`.
- Both native iPhone UI tests passed. Creating Clara Watson and Pepper updates the already-open Clara search; searching Pepper finds the new owner, and clearing the search restores all 1,001 owners without restarting.
- macOS arm64 Debug build passed.
- Local persistence validation and its five unit tests passed. No schema or migration changes were made.
- No new SwiftLint findings were introduced in the changed Swift files.
- A fresh CodeRabbit review of the implementation and test infrastructure returned zero findings after addressing its earlier minor observations.

The final clean unit result is `/tmp/pawtrackr-search-stress-units-shipping.xcresult` (50 passed, zero failed); the final native UI result is `/tmp/pawtrackr-search-stress-ui-final.xcresult` (two passed, zero failed). The main latency attachment comes from the final unit result. The macOS build log is `/tmp/pawtrackr-search-stress-macos-shipping.log`.

During UI test development, the harness was corrected to recognize SwiftUI's localized `1,000` count and to drag the form above the iPhone number pad instead of swiping through the keyboard. These were automation corrections; they did not require product layout changes.

To rerun, resolve a currently available Simulator UUID with `xcrun simctl list devices available`, then use the shared `Pawtrackr` scheme and that UUID:

```sh
xcodebuild test -project Pawtrackr.xcodeproj -scheme Pawtrackr \
  -destination 'id=<available Simulator UUID>' \
  -only-testing:PawtrackrTests/ClientSearchStressTests \
  -only-testing:PawtrackrTests/ClientSearchPrecisionTests \
  -only-testing:PawtrackrTests/ClientManagementRegressionTests \
  -only-testing:PawtrackrTests/ClientsViewModelListTests \
  -only-testing:PawtrackrTests/LocalStoreCommitBridgeTests \
  -only-testing:PawtrackrTests/PhoneUtilsTests \
  -only-testing:PawtrackrUITests/ClientSearchStressUITests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```
