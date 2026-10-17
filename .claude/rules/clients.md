---
paths:
  - "Pawtrackr/Features/Clients/**"
  - "Pawtrackr/UI/Components/IconCircle.swift"
  - "Pawtrackr/Core/Storage/Repositories/Client*.swift"
---

# Clients Rules

- `ClientsViewModel` fetches identifiers in the background through `ClientRepository`; the client grid has no `@Query`.
- Grid identity: rows use `ForEach(clients, id: \.persistentModelID)`, and the container uses `.id("\(viewModel?.sortOption.rawValue ?? "")_\(clients.count)")`. The `.clientList` walkthrough anchor comes from a `Color.clear` background on the first card (`clientListAnchor(isActive:)`). Never attach an `.id` or anchor to the row view itself: a parent anchor clobbers the nested ones.
- `ClientListOrdering` compares names with `localizedStandardCompare`, sorts by a client's first alphabetical active pet for the pet-name option, then by creation date, and breaks final ties with a lexical `uuid.uuidString <` (never a localized compare on UUIDs), so the order is stable.
- `AvatarView` / `IconCircle` derive initials from the canonical "First Last" name; combining marks are cleaned without breaking ZWJ or skin-tone emoji (`AvatarIdentityTests`).
- New clients go through `ClientRepository` → `ClientCreationCoordinator`, an actor that serializes creation and inserts the `AppNotification` in the same save as the client.
- Behavior badges, auras and the aggressive banner follow `.claude/rules/pet-behavior.md`.
