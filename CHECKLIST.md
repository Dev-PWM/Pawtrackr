# Pawtrackr diagnostic checklist — 2026-10-17

Audited the current checkout `f8317770da36cd8548f85040fbc129f3fc023402`, which follows the brief's `80ddc19` reference. Existing deletions of 45 root build logs and three history dumps were preserved. The completed changes are prepared for direct delivery to `Master`.

## Environment and agent configuration

- [x] Updated the active npm Codex CLI from 0.139.0 to 0.163.0 and native Claude Code from 2.1.201 to 2.1.302. Installed SwiftLint 0.65.1. CodeRabbit CLI is 0.9.0 and authenticated.
- [x] Confirmed `$HOME/.local/bin` is on interactive login zsh PATH. Active Claude resolves to the native installation. Homebrew also holds Claude 2.1.236; the ChatGPT application bundles another Codex binary. These separately managed installations were identified and preserved; the active versions above are selected by PATH.
- [x] `claude doctor`: native install, bundled search and auto-updates healthy; no installation issues. Remote Control authentication lacks the profile scope and was not changed by this repository task.
- [x] Parsed all repository Codex TOML, `~/.codex/config.toml`, `skills-lock.json`, `.vscode/settings.json`, and local/user Claude settings. Parsed frontmatter for the Claude agent, seven scoped rules and both active skills with Ruby's YAML parser.
- [x] Checked the notification executable, local marketplace paths, enabled MCP executables and absolute argument paths, Run action and canonical skill files. Removed one disabled legacy computer-use MCP entry whose executable no longer exists; the original global config is backed up privately at `~/.codex/config.toml.backup-20261017-health`. `skills-lock.json` records upstream source paths; those paths are not local installation destinations.
- [x] Global Codex already used `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`; `.codex/config.toml:2` now makes those defaults explicit for the trusted project. Global Claude already used `auto`; `.claude/settings.json:3` also makes it explicit here.
- [x] Validated all 16 verification prefixes in `.codex/rules/verification.rules:2` with `codex execpolicy check`. Branch-deletion commands do not match the read-only branch rules. Both tools use the actual shared `Pawtrackr` scheme, with `-only-testing:` for the two test targets.
- [x] QA instruction bodies in `.codex/agents/pawtrackr-qa-sovereign.toml:3` and `.claude/agents/pawtrackr-qa-sovereign.md:9` match. Removed obsolete runtime examples, staged-migration/cloud modules, tip instructions and hardcoded memory paths. Each profile shrank from about 23 KB to 2.7 KB.

## Context and documentation repairs

- [x] Removed 48 third-party skill trees only after comparing every non-metadata file's bytes with the canonical `.claude/skills` copies. `.gitignore` prevents mirrors, root logs and history dumps from returning to ordinary search results.
- [x] Removed retired CloudKit implementation documents. `docs/XcodeCloudDeployment.md:24` now describes the existing local persistence/fixture gates. Historical loyalty plans/specs are marked as superseded by ADR-0003/0004/0005 and the paused subscription policy.
- [x] Root `AGENTS.md:3` retains architecture invariants and routes cross-cutting work to scoped rules; app conventions and `ARCHITECTURE.md` no longer repeat storage policy. Five nested `AGENTS.md` files own storage, clients, checkout, walkthrough and theme guidance. Their nested `CLAUDE.md` files import the shared body; path-scoped Claude rules also cover files and tests outside those directories.
- [x] `Pawtrackr.xcodeproj/project.pbxproj:32` excludes all 11 app-source agent documents from synchronized target membership. The built iPhone app contains no `AGENTS.md` or `CLAUDE.md` resources.

Git ignore patterns reduce normal search noise. They do not prohibit file access or create a universal Codex context-indexing filter. Installed user/plugin skills remain available independently of repository mirrors.

## Code repairs and accuracy

| File / anchor | Root cause and change | Verification |
| --- | --- | --- |
| `ci_scripts/test_validate_local_persistence.py:5` | Direct import failed under the brief's `python3 -m unittest ...` command. Support both package and direct-script invocation. | Both invocation forms pass all five tests. |
| `.swiftlint.yml:15` | `unused_private_declaration` was not a supported rule identifier. Use `unused_declaration`. | Rule listing and lint run have no configuration warning. |
| `PawtrackrTests/ClientEditConflictTests.swift:232` | An observation callback mutated a captured Boolean concurrently. Protect its read/write with `OSAllocatedUnfairLock`. | Full unit suite; concurrent-capture compiler warning removed. |
| `Pawtrackr/UI/Theme/DesignSystem.swift:42` | Fixed/system colors did not implement the requested dual palette. Add native UIKit/AppKit dynamic sRGB providers, surfaces, borders, text and semantic colors. Old default brand values adapt while explicit custom branding survives. | Theme tests on iOS and macOS, including AA secondary-text contrast on all three surfaces. |
| `Pawtrackr/UI/Theme/BehaviorTagIcons.swift:19` | Behavior colors diverged from the requested adaptive palette. Share emerald, blue, amber and crimson tokens. | Unit build, behavior and motion tests; readable warning labels retained. |
| `Pawtrackr/UI/Components/Card.swift:84` and `CardElevation.swift:36` | Cards used unrelated backgrounds/separators and ungoverned press/hover springs. Use semantic surfaces/borders/text and MotionGovernor; soften warm light-mode shadows and use surface luminance for dark elevation. | iOS/macOS builds; theme/motion suites. |
| `Pawtrackr/UI/Components/PetBehaviorAura.swift:23` | Resource-limited mode still rendered a blurred glow. Use only the static hairline fallback when animation is disallowed. | MotionGovernor and behavior safety suites. |
| `Pawtrackr/Core/Services/PDFReceiptService.swift:131` | Several receipt strings relied on implicit text ink; accent colors could resolve by appearance. Explicitly draw fixed paper/ink/hairline colors for every section. | Rasterized receipt pages match across light/dark appearance and contain opaque visible ink on macOS; iOS receipt suite also passes. Business report colors were already fixed and remain so. |
| `PawtrackrTests/PDFReceiptServiceTests.swift:117` | Initial new test counted low bitmap bytes, which could include transparency. White-fill the raster and count dark RGB pixels. | Nine-test native retest passes; fresh CodeRabbit test review reports no findings. |
| `Pawtrackr/Features/Walkthrough/WalkthroughOverlay.swift:945` | Implement the requested compact iPhone GPU cutout with destination-out compositing. Keep existing safe-area geometry and desktop/iPad even-odd Canvas. | Geometry unit tests pass; compact UI validation below. |

### Confirmed dead declarations

Scanned all 242 original app Swift files and checked references across app, unit/UI tests and QualityControl. Removed unused private declarations and three unreferenced legacy views. Kept `signInWithPIN`, which is called by authentication tests. No store model or schema property was removed. The unused `SummaryUpdater.rebuildDaySync` bypassed equality guards; active rebuild paths retain equality-checked writes and relationship prefetching.

The locations below refer to the baseline before removal; validation is the full unit suite plus platform builds.

| Baseline file | Removed symbol / view | Baseline line |
| --- | --- | --- |
| `Pawtrackr/Features/Insights/InsightsView.swift` | `showRevenueDrilldown` | 790 |
| `Pawtrackr/Features/Insights/InsightsView.swift` | `showCategoryDrilldown` | 802 |
| `Pawtrackr/Features/Insights/InsightsView.swift` | `percentString` | 835 |
| `Pawtrackr/Features/Clients/ClientRow.swift` | `accessibilityLabel` | 71 |
| `Pawtrackr/Features/Clients/NewClientViewModel.swift` | `loadAvatarImage` | 66 |
| `Pawtrackr/Features/Clients/ClientDetailView.swift` | `openClientWindow` | 1284 |
| `Pawtrackr/Features/Clients/ClientDetailView.swift` | `clientInitials` | 1625 |
| `Pawtrackr/Features/Clients/ClientDetailView.swift` | `humanDuration` | 1709 |
| `Pawtrackr/Features/Checkout/CheckoutView.swift` | `stepTransition` | 216 |
| `Pawtrackr/Features/Checkout/CheckoutView.swift` | `safetyBehaviorTags` | 1083 |
| `Pawtrackr/Features/Dashboard/DashboardView.swift` | `recentHistoryLink` | 1012 |
| `Pawtrackr/Features/Dashboard/DashboardView.swift` | `openPet` | 1060 |
| `Pawtrackr/Core/Storage/StoreFileMigration.swift` | `openReadable` | 423 |
| `Pawtrackr/Core/Storage/SummaryUpdater.swift` | `rebuildDaySync` | 493 |
| `Pawtrackr/App/MainTabView.swift` | `appSettings` | 6 |
| `Pawtrackr/App/MainTabView.swift` | `authViewModel` | 7 |
| `Pawtrackr/App/RootView.swift` | `appSettings` | 16 |
| `Pawtrackr/App/ContentView.swift` | `authViewModel` | 33 |
| `Pawtrackr/Features/Insights/InsightsActor.swift` | `insightsLog` | 13 |
| `Pawtrackr/Features/Settings/SettingsView.swift` | `pinChangeError` | 138 |
| `Pawtrackr/Features/Onboarding/LoginView.swift` | `appSettings` | 6 |
| `Pawtrackr/Core/Storage/ImportService.swift` | `log` | 9 |
| `Pawtrackr/Core/Services/PredictiveSchedulingActor.swift` | `predictiveLog` | 13 |
| `Pawtrackr/Core/Storage/Repositories/ClientRepository.swift` | `clientRepoLog` | 13 |
| `Pawtrackr/Features/Insights/InsightsView.swift` | `categoryDrilldownRows` | 814 |
| `Pawtrackr/Features/Insights/InsightsView.swift` | `visitDrilldownRows` | 825 |
| `Pawtrackr/Features/Clients/ClientRow.swift` | `formattedPhone` | 79 |
| `Pawtrackr/Features/Checkout/CheckoutViewModel.swift` | `visitRepository` | 102 |
| `Pawtrackr/App/MainTabView.swift` | `entire unreferenced view` | 1 |
| `Pawtrackr/Features/Onboarding/LoginView.swift` | `entire unreferenced view` | 1 |
| `Pawtrackr/UI/Theme/MeshGradientView.swift` | `entire unreferenced view` | 1 |

## Verification results

| Check | Result |
| --- | --- |
| TOML/JSON/YAML, config paths, QA parity, Run executable | Passed |
| 16 Codex execution prefix rules plus branch-deletion counterexample | Passed |
| Local persistence validator, five Python tests, pre-Xcode CI gates | Passed |
| `plutil -lint` project and `git diff --check` | Passed |
| Initial iPhone full unit run | 743 tests passed, zero failures |
| Updated iPhone full unit run including new theme/receipt coverage | 747 tests passed, zero failures |
| Native macOS app build | Passed; final source rebuilt successfully with explicit arm64 destination |
| Native macOS theme, receipt and business-report run | 17 tests passed, zero failures |
| Native macOS strengthened print/theme retest | 9 tests passed, zero failures |
| Compact iPhone walkthrough UI tests | All 3 passed again in the final clean run. The saved result bundle reports 750/750 passed (747 unit + 3 UI), zero failures and zero skips. |
| Final iPhone print/theme retest | All 9 theme/receipt tests passed within the final 747-unit-test run, including the strengthened visible-ink assertion. |
| Fresh CodeRabbit source and test reviews | Zero outstanding findings; one test-strengthening finding fixed |
| SwiftLint lint | 2,492 findings: 270 errors and 2,222 warnings; baseline 2,526 (277 errors, 2,249 warnings). No new findings by file/rule/source-line comparison. |
| SwiftLint compiler-backed analysis | Stopped after the host reached ENOSPC while SourceKit generated module caches; no clean compiler-backed analyzer result is claimed. The full source reference scan and ordinary lint completed. |

The full unit run includes `CheckoutCentAllocationTests`, `MoneyArithmeticTests`, `CheckoutIdempotencyTests`, `ClientSearchPrecisionTests`, `PhoneUtilsTests`, `LocalStoreCommitBridgeTests`, `GlobalEventBusTests`, `SummaryUpdaterTests`, `SummaryRebuildIdempotencyTests`, `BehaviorSafetyAlgorithmTests`, `MotionGovernorTests`, `AvatarIdentityTests`, `NavigationRouterTests`, `StoreUpgradeRegressionTests` (all six tests against the two shipped fixtures), and `MemorySafetyTests` (including 100 view-model lifecycles).

### Commands and evidence

The final verified bundle is `/tmp/pawtrackr-health-verified.xcresult`; `xcresulttool get test-results summary` confirms `Passed`, 750 passed, 0 failed, 0 skipped.

All Xcode commands use `-project Pawtrackr.xcodeproj -scheme Pawtrackr`, `CODE_SIGNING_ALLOWED=NO` and isolated temporary DerivedData. Test bootstrap uses in-memory stores; production user data was not opened for testing.

- `python3 ci_scripts/validate_local_persistence.py`
- `python3 -m unittest ci_scripts/test_validate_local_persistence.py`
- `python3 ci_scripts/test_validate_local_persistence.py`
- `bash ci_scripts/ci_pre_xcodebuild.sh`
- `xcodebuild test ... -destination id=71C8B24E-5247-4E44-89BE-9BCD0968FCB0 -only-testing:PawtrackrTests -only-testing:PawtrackrUITests/WalkthroughCompactUITests -parallel-testing-enabled NO -collect-test-diagnostics never -enableCodeCoverage NO`
- `xcodebuild build ... -destination platform=macOS`
- `xcodebuild test ... -destination platform=macOS -only-testing:PawtrackrTests/ThemePaletteTests -only-testing:PawtrackrTests/PDFReceiptServiceTests -only-testing:PawtrackrTests/BusinessReportTests`
- `swiftlint lint --quiet --reporter json`; baseline lint used an extracted HEAD snapshot with the same SwiftLint version.
- `swiftlint analyze --quiet --compiler-log-path /tmp/pawtrackr-health-macos-tests.log --reporter json`
- `coderabbit review --agent --uncommitted --include-untracked --dir <app-or-test-directory>`; the test verification explicitly used `--fresh`. No historical dump deletions were uploaded.

Evidence lives in `/tmp/pawtrackr-health-*.log`, `/tmp/pawtrackr-health-verified.xcresult`, `/tmp/pawtrackr-health-unit.xcresult`, `/tmp/pawtrackr-health-macos-tests.xcresult` and `/tmp/pawtrackr-health-print-final.xcresult`, `/tmp/pawtrackr-health-swiftlint-final.json` and `/tmp/pawtrackr-health-coderabbit-*.ndjson`; raw build/session logs were kept out of the repository.

## Remaining limits

- The host reached about 115 MB free during optional compiler-backed analysis. That interrupted one follow-up iPhone installation and the combined result-bundle save. Only this task's temporary caches and incomplete bundles were cleared; the full verification was restarted with verbose failure diagnostics disabled and completed successfully (750/750). The full test logs from the earlier passing run are retained. After the verified run, task-owned compiler/index caches were cleared again; 1.22 GiB free remained. App products and the complete result bundle were preserved.

- Lint remains non-green because of existing style/complexity debt. This change reduces findings without adding blanket suppressions or altering active business logic to satisfy style rules.
- Existing compiler diagnostics on weak reference probes in lifecycle tests remain documented; changing those probes to strong references would invalidate the tests. The app build also emits Xcode's metadata-extraction notice because it has no App Intents dependency. Simulator keychain diagnostics under unsigned testing do not represent a signed-release validation.
- No measured 60/120-fps claim, Instruments leak profile, long-running device soak or real App Store installation-over-upgrade is claimed. Before release, perform the old-build/new-build physical-device upgrade procedure from the storage guide.
