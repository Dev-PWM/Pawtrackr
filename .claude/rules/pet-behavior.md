---
paths:
  - "Pawtrackr/Core/Storage/Models/Pet.swift"
  - "Pawtrackr/UI/Theme/BehaviorTagIcons.swift"
  - "Pawtrackr/UI/Components/PetBehaviorAura.swift"
  - "Pawtrackr/Features/Clients/**"
  - "Pawtrackr/Features/Checkout/**"
  - "PawtrackrTests/BehaviorSafetyAlgorithmTests.swift"
---

# Pet Behavior Rules

- Aggression clears only after 3 completed, explicitly observed non-aggressive visits: calm, cooperative, anxious or nervous, in any combination (`Pet.aggressionClearanceStatus`). An aggressive visit resets the count immediately. Untagged and special-needs-only visits neither advance nor break it. Never preselect a previous temperament on a new checkout.
- Special needs is a standing priority-care flag, separate from temperament. Checkout preserves it until it is edited on the profile. When aggression and special needs coexist, show both warnings.
- Keep the client-level aggressive banner and the pet safety badge. Don't duplicate the aggressive warning as an emoji pill.
- Colors come from `BehaviorTagIcons.tint`: aggressive crimson (`danger`), special needs amber (`specialCare`), anxious/nervous blue (`calmBlue`), calm/cooperative emerald (`success`). Glow precedence follows that order. Chips and checkout choices share adaptive colors; after clearance show the latest observation rather than accumulated moods.
- `PetBehaviorAura` supplements readable labels and never replaces a safety warning. Its animation stops under Reduce Motion, in the background, in Low Power Mode, or under thermal pressure (`MotionGovernor`, `MotionGovernorTests`).
- Behavior tags are stored localized (English and Spanish). Classify them with `Pet.isAggressiveTag` and the other `Pet` matchers, which accept both languages; never compare raw tag strings.
