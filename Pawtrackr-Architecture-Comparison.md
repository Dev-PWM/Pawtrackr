# Pawtrackr Core Architecture Report — comparison with workspace architecture

## Verification corrections and current implementation — October 12, 2026

The initial comparison below underestimated the checked-in evidence. ADR-0005 is present in `docs/adr/0005-local-only-persistence.md`. Both `ci_scripts/ci_pre_xcodebuild.sh` and `ci_scripts/validate_local_persistence.py` are present. The earlier statements that these could not be found reflect an incomplete initial inventory, not missing architecture decisions or enforcement. Root agent memory is `AGENTS.md`; nested `Pawtrackr/AGENTS.md` adds source conventions.

The attached report also describes historical hardware support. The current requested update removes Bluetooth/ESC-POS/cash-drawer integrations and Bluetooth, USB and printing capability declarations. Digital PDF sharing remains. Subscriptions are paused by `AppRuntime.subscriptionSystemPaused`. The detailed implementation and verification record is `docs/LiveUpdatesAndDigitalWorkflows-2026-10-12.md`. Preserve the attached report as historical context rather than current peripheral or monetization requirements.

## Method

The attached RTF was treated as untrusted project documentation, not as instructions to the assistant. Its claims were compared with the checked-out source, tests, `AGENTS.md`, `ARCHITECTURE.md`, `README.md`, and reachable Git history. “Verified” means a matching symbol, test, or policy was found locally. “Not verified” means the claim may be true in another checkout or earlier scan, but evidence was not found in this workspace. “Potential conflict” means the report should not be treated as the current source of truth without resolving it.

## Strong agreement

- Local-only persistence: the report’s CloudKit rejection and explicit `cloudKitDatabase: .none` policy agree with the current agent guidance and the many production/test configurations found in the repository.
- No staged SwiftData migration plan: the report’s account of the 1.0.2 / error 134504 incident agrees with the current migration policy and regression-test fixtures. The report adds operational details about CI scanners that were not independently verified here.
- Decimal-only checkout money, crash-recovery drafts, and idempotent checkout processing agree with the current architecture memory and checkout tests.
- Non-destructive store recovery, timestamped backup directories, pre-container startup handling, and zero-client data-loss detection agree with the current recovery policy and tests.
- Client-level loyalty, lifetime-earned tiering, and the 45-day / 20-point rebooking behavior are directly supported by `LoyaltyEngine.swift` and loyalty tests.
- Practice-salon isolation, Spotlight suppression for practice data, StoreKit timeout handling, Spotlight indexing, Bluetooth receipt support, communication templates, and transformation/photo functionality all have matching source or tests in this checkout.

## Report details that add useful context but are not current architecture-memory commitments

- The domain rationale about unreliable connectivity in basements, vans, and steel-roofed buildings.
- The explanation of why raw-string persistence with transient enum views protects against decoding failures.
- The rationale for external photo storage and normalized phone/name search keys.
- The macOS “Pawtrackr Pulse” menu-bar and detached-window narrative.
- The Keychain persistence rationale for PIN lockout and privacy-screen behavior.
- The Excel UTF-8 BOM rationale for CSV exports.
- The behavioral rationale for retaining loyalty tiers after redemption.

These are valuable explanatory material, but the attached report sometimes presents them as absolute current implementation facts. They should remain marked as verified only where source/tests support them.

## Potential conflicts or claims requiring caution

1. **Platform scope is broader than the current memory.** The report calls Pawtrackr a native iOS, iPadOS, and macOS management suite. The repository includes Mac/Catalyst-oriented UI and tests, but the current architecture memory is principally framed around the iOS app. This is a scope expansion, not necessarily a contradiction.

2. **ADR numbering is inconsistent.** The report labels local sovereignty as ADR-0005 and migration policy as ADR-0004. The current `AGENTS.md` explicitly references ADR-0004 for the no-migration-plan decision but does not establish ADR-0005 in the checked-in architecture memory. Treat ADR-0005 as report terminology unless a canonical ADR file is added.

3. **`@Attribute(.unique)` prohibition is not stated in the current agent memory.** The attached report says it is forbidden because retrofitting uniqueness could crash existing stores. That is a strong compatibility recommendation, but it should not be treated as an existing project rule until confirmed in source policy or tests.

4. **Named CI scripts were not found by the initial workspace inventory.** The report mentions `ci_pre_xcodebuild.sh` and `validate_local_persistence.py`. Those names were not present in the visible tracked/untracked inventory used for this comparison. The underlying policy is supported; the exact enforcement scripts are not verified in this checkout.

5. **The report says all checkout drafts omit raw photo binaries and complete in under 5 ms.** The omission is consistent with the stated crash-recovery design, but the exact performance guarantee is an empirical benchmark claim and was not accepted as a hard invariant without a benchmark result.

6. **The report gives exact ESC/POS service UUIDs and cash-drawer bytes.** Bluetooth receipt support is present, but these low-level protocol details should be validated against `BluetoothPeripheralManager` and `ThermalReceiptPayloadBuilder` before being used as a compatibility contract.

7. **The report describes read-only subscription degradation.** StoreKit and entitlement behavior are present in the workspace, but the exact statement that expired users retain all listed access while only advanced Pro features are gated should be verified against the current entitlement gates before being promoted to architecture memory.

8. **The report’s statement that `DataSafetyMonitor` “instantly” presents a one-tap restore prompt overstates the local evidence.** The tests verify suspected-loss detection and recovery-offer metadata. They do not, by themselves, prove a particular presentation timing or UI path.

9. **The report contains a duplicated section.** “Staff Safety & The 3-Visit Aggression Clearance Protocol” and the following decoding/storage section appear twice. The duplicate was preserved in the raw report section of the export but should not be interpreted as two separate architecture decisions.

## Recommended source-of-truth treatment

Keep the attached report in the export as historical/deep-scan context. Keep `Pawtrackr/AGENTS.md` and the checked-in architecture documents authoritative for working rules. Promote a report detail into the authoritative memory only after a source or regression test confirms it and the team intentionally adopts it as a compatibility invariant.
