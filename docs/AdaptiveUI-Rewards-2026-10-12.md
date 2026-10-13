# Adaptive UI, Academy focus, and visit rewards

## Implemented behavior

- Navigation labels and symbols use adaptive primary foregrounds: dark text in light appearance, light text in dark appearance. Selection has a neutral surface highlight.
- Shared tinted avatars use adaptive foregrounds. Ordinary cards cast neutral shadows; colored glows are reserved for behavior and reward cues.
- Pet action cards have a rear behavior glow and a 3-point border along the card edge. Existing aggression, priority-care, anxiety, nervousness, and calm/cooperative precedence remains intact. Animation retains the motion governor and scene-phase gate.
- Academy shows the sidebar for the app map and Dashboard, Clients, Insights, and Settings navigation targets. Content lessons collapse the sidebar. Compact iPhone navigation stays available. Ending the Academy restores the ordinary split-view layout.
- Academy lesson paragraphs use an 18-point base that scales with Dynamic Type. Long content scrolls within the available lesson card height, with navigation controls retained.
- Client profiles and Payment show available rewards from the current salon catalog. Eligible Spa Package has a gift marker, a stronger outline and a glow on Services. Selecting the service remains available at any points balance.
- Staff explicitly choose the reward in Payment. No points are spent before confirmation. The actor validates the current catalog, saved balance, and selected Spa Package before committing.
- VIP Spa redemption waives the entered checkout service amount, including the selected add-ons. It is a full checkout service waiver because this flow uses one staff-entered amount rather than separate staff-entered line prices. The UI states this before confirmation. Editing that amount cannot reintroduce a charge while the reward remains selected.
- Salon credits continue to deduct their explicit Decimal amounts. Credits larger than the entered subtotal cannot consume points.
- Each newly settled completed visit earns exactly 20 points, including a free reward visit. Tier and rebook timing do not multiply this award. Old earning fields remain in the model for store compatibility. Previously awarded visits retain their original earnings and balance when reprocessed.
- Existing transaction idempotency, Decimal totals, critical draft saving, actor persistence, and local-only storage remain the transaction boundaries.

## Regression coverage

AutomaticVisitLoyaltyTests covers settled/unpaid/partial payments, zero-cost earning, historical balance preservation, spa service validation, manual-price waiver, retry and concurrent confirmation, saved-balance limits, and Decimal credits. LoyaltyPreviewTests checks preview/persistence parity across prices, tiers and legacy configurations. CheckoutFlowTests checks payment, receipts, fixed awards, and price edits. WalkthroughTourTests checks navigation visibility per target. CheckoutHistoryIntegrationTests and CheckoutIdempotencyTests exercise persisted history and repeated transactions.

## Verification results

- Final macOS build and launch: passed through `script/build_and_run.sh --verify`.
- Final iOS simulator build: passed on resolved iPad destination `D1F6BB7E-97D6-4097-8A20-7B10DD55561A`.
- Six selected regression suites on resolved iPhone simulator `71C8B24E-5247-4E44-89BE-9BCD0968FCB0`: 86 tests, zero failures. The macOS test host hit a signing configuration issue; the regression suites were executed on iOS instead.
- Desktop visual inspection: verified light/dark navigation contrast, the calm pet's rear green aura, eligible VIP Spa notice, readable History action in light mode, and neutral history selection.
- Desktop Academy replay: observed app-map sidebar visible, Today lesson sidebar hidden, Back restoring the sidebar, and Skip exiting the practice salon with normal navigation restored. Restored the original dark appearance after inspection.
