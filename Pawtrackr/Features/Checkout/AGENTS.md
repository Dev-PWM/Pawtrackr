# Checkout Rules

- `CheckoutViewModel` is the only owner of checkout UI state. `CheckoutView` can bind to editor buffers, but every persisted value flows back through the view model before navigation or confirmation.
- The groomer types the visit amount (`amountString` → `baseAmountDecimal`). Service and add-on selections never assign, replace, or supply a fallback price; legacy catalog-price fields stay only for store compatibility and historical receipt allocation.
- Checkout takes no tips. `CheckoutDraft` keeps `tipAmountString` / `selectedTipPercentage` only so older drafts still decode; restore ignores them.
- The 4-step draft is a crash-recovery boundary. Step transitions, payment method changes and external references save immediately; other edits debounce 450 ms in `CheckoutViewModel.scheduleDraftSave`. `makeDraft()` drops photo `Data` and records `hadBeforePhoto` / `hadAfterPhoto` instead. Walkthrough previews never write drafts.
- Draft disk I/O stays off the main actor: `CheckoutDraftStore` is an actor for ordering, and its JSON/file reads and writes run in detached utility tasks.
- Confirm-and-pay is protected twice: a view-model debounce blocks rapid duplicate taps, and `CheckoutTransactionActor` is idempotent on `"checkout:\(visitUUID)"`.
- `CheckoutTransactionActor` acquires `LoyaltyMutationGate.shared.acquire(balanceKey)` and releases it on every path, validates rewards with `LoyaltyRedemptionProcessor`, and rebuilds daily rollups with `SummaryUpdater.rebuildDay`.
- `reconcileLineItemPrices` spreads the final total and reward discounts across `VisitItem`s with largest-remainder cent allocation, so line items sum exactly (`CheckoutCentAllocationTests`).
- Checkout success must not hide cleanup or refresh failures: log draft-deletion and main-context refresh errors instead of swallowing them with `try?`.
- Behavior tags written at checkout follow `.claude/rules/pet-behavior.md`.
