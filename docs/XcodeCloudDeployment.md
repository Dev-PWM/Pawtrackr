# Xcode Cloud Deployment

Pawtrackr uses Xcode Cloud custom scripts in `ci_scripts/` for repository-owned preflight checks. Xcode Cloud recognizes these names when they are executable and stored next to `Pawtrackr.xcodeproj`:

- `ci_post_clone.sh`
- `ci_pre_xcodebuild.sh`
- `ci_post_xcodebuild.sh`

Apple documents this convention in [Writing custom build scripts](https://developer.apple.com/documentation/Xcode/Writing-Custom-Build-Scripts).

## Workflow

Create an Xcode Cloud workflow named `Pawtrackr Enterprise TestFlight`.

- Product: `Pawtrackr`
- Scheme: `Pawtrackr`
- Branch start condition: primary branch `Master`
- Actions: Analyze, Test, Archive
- Test plan: `TestPlan.xctestplan`
- Post-action: Distribute successful archives to the internal employee TestFlight group

## Environment

Persistence stays on the device under ADR-0005. Builds require no CloudKit schema deployment or management token.

Configure these Xcode Cloud environment variables:

- `PAWTRACKR_ENTERPRISE_ENVIRONMENT`: non-secret build environment label, for example `production`
- `VAULT_SECRET_TOKEN`: secret token available to scripts or signing/upload tools

Do not write `VAULT_SECRET_TOKEN` into `Info.plist`. Values stored in `Info.plist` are bundled into the app and are visible to anyone with the app binary. The preflight script only injects non-secret environment metadata and confirms when the secret exists.

## Gates

The scripts currently enforce:

- no `FIXME_TRANSLATION` markers in localized resources
- valid iOS Info.plist syntax
- no SwiftData migration plan in the app target (ADR-0004)
- no unique constraint on a model in `PawtrackrSchema.models`
- local-only model configurations, containers and entitlements via `validate_local_persistence.py` (ADR-0005)
- shipped store fixture availability for additive-upgrade regression coverage
- `PawtrackrTests` and `PawtrackrUITests` inclusion in `TestPlan.xctestplan`
- QualityControl chaos test source presence

The Xcode Cloud workflow should own the actual test/archive/TestFlight execution so Apple can attach result bundles, logs, and TestFlight distribution status to the build report.

## Manual Release Checks

Before submitting a build that changes SwiftData models:

- run the old-build -> new-build upgrade test on a real device without deleting the app
- add this release's store to `PawtrackrTests/Fixtures` (see `StoreFixtures.md`) and keep `StoreUpgradeRegressionTests` passing; there is no migration chain to extend (ADR-0004)
