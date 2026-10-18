# Theme Rules

- Resolve colors dynamically on UIKit and AppKit. Canvas: `#F7F6F2` / `#110E14`; cards: `#FFFFFF` / `#1B1720`; elevated surfaces: `#FCFCFA` / `#241F2B`; borders: `#E5E2DC` / `#2E2836` (light / dark).
- Text: `#141417` / `#F4F2F7` primary, `#5C5A66` / `#A39CAD` secondary. Default brand: `#5B4FE9` / `#7C72FF`. Preserve user-selected brand colors.
- Behavior colors use `BehaviorTagIcons.tint`: calm/cooperative emerald `#059669` / `#10B981`; nervous/anxious blue `#0284C7` / `#0091FF`; special needs amber `#D97706` / `#F59E0B`; aggressive crimson `#DC2626` / `#EF4444`. Keep readable safety labels alongside color.
- `MotionGovernor.shouldAnimate` governs decorative motion, including mesh backgrounds, card springs and pet auras. Stop motion in inactive scenes, Reduce Motion, Low Power Mode and serious/critical thermal states; use static borders instead of blur/glow workloads.
- PDFs use fixed print-safe paper, ink and hairline colors independent of app appearance. Never use dynamic `DS.ColorToken` values in `BusinessReportService` or `PDFReceiptService`.
- Preserve macOS window geometry, desktop grids, detached windows and native sidebar material.
