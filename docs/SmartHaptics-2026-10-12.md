# Context-aware haptic feedback

## Behavior

Pawtrackr sends semantic events through one main-actor native dispatcher: press, selection, navigation, Academy/checkout step, confirmation, reward choice, success, warning, and error. Existing impact and notification call sites continue through the same policy.

Selections use native selection feedback on iOS and alignment feedback on macOS. Reward choices use a soft impact; confirmation uses a medium impact. Successful persistence, warnings and failures use native outcome feedback. macOS uses the corresponding supported AppKit trackpad patterns; exact tactile patterns differ by platform.

The policy uses monotonic uptime and never queues delayed feedback. Rapid duplicate events are dropped. A confirmation or outcome can pass immediately after a press, while a brief quiet interval prevents incidental touches from obscuring an outcome. Different outcomes remain eligible immediately. Disabled, background and unsupported-device events are dropped without consuming a future event's cooldown. Low-power or serious/critical thermal conditions suppress incidental cues while retaining confirmation and result cues.

Native iOS generators are reused, with selection/impact preparation for near-future interactions and explicit success preparation before check-in and checkout saves. Hardware support is queried through Core Haptics. No continuous haptic engine, audio fallback, or custom timed vibration sequence is created.

The existing haptics setting remains authoritative on every call. Settings changes reset transient arbitration; re-enabling produces a selection cue when supported and foregrounded. Settings > Preferences > Brand & Feedback includes translated explanatory text and a Try Feedback button, disabled when haptics are off.

## Correctness fixes

- Removed the duplicate checkout success notification from the view. The view model signals success once the transaction and completion handling finish.
- Check-in success moved from pet/client buttons to their view models after the repository commit. Save failures use error feedback.
- Opening checkout is navigation feedback, not a completed-payment success cue.
- Service/add-on/payment/tag choices use selection feedback. Changing the reward has a separate soft cue; choosing the same reward again produces no additional signal.
- Academy navigation and chapter outcomes also work through the macOS mapping. Exiting a tour early produces no warning.
- Both button-style entry points share disabled-state and Reduce Motion-aware animation behavior. Reduce Motion does not disable useful tactile feedback independently of the explicit haptics preference.

## Recovery

Reconstructed on the fresh clone at commit d313255 after the local project folder was removed. That commit already contains the adaptive UI, Academy focus, spa redemption and fixed visit-earning work. The haptics changes restore the previously unpushed implementation from this session.

A Git patch including source, regression tests and this document is saved outside the project in /Users/mac/.codex/recovery/Pawtrackr. Apply it to a clean checkout of d313255 with git apply if another copy is needed.

## Verification

The recovery run passed the macOS build and launch through script/build_and_run.sh --verify. On the resolved iPhone simulator 71C8B24E-5247-4E44-89BE-9BCD0968FCB0, all 97 tests passed with zero failures: HapticFeedbackPolicyTests (11), CheckoutFlowTests (7), AutomaticVisitLoyaltyTests (22), ClientDetailViewModelTests (18), and WalkthroughTourTests (39).

Native Settings inspection confirmed the restored explanation and Try Feedback control. Turning Haptic Feedback off disabled the preview, and re-enabling it restored the control. The original enabled preference was restored.

Physical actuator feel cannot be established from a simulator or accessibility snapshots. Use Try Feedback on a supported iPhone or Force Touch trackpad for tactile acceptance testing.

## Apple API references

- https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator
- https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare()
- https://developer.apple.com/documentation/corehaptics/chhapticengine/capabilitiesforhardware()
