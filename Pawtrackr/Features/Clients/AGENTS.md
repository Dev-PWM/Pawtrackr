# Clients Rules

- `ClientsViewModel` fetches identifiers in the background through `ClientRepository`; the client grid has no `@Query`.
- Grid identity: rows use `ForEach(clients, id: \.persistentModelID)`, and the container uses `.id("\(viewModel?.sortOption.rawValue ?? "")_\(clients.count)")`. The `.clientList` walkthrough anchor comes from a `Color.clear` background on the first card (`clientListAnchor(isActive:)`). Never attach an `.id` or anchor to the row view itself: a parent anchor clobbers the nested ones.
- `ClientListOrdering` compares names with `localizedStandardCompare`, sorts by a client's first alphabetical active pet for the pet-name option, then by creation date, and breaks final ties with a lexical `uuid.uuidString <` (never a localized compare on UUIDs), so the order is stable.
- Client Center avatars take one initial per name field in the displayed sort order: Last Name uses MA for Martinez Ava; First Name uses AM for Ava Martinez. Other surfaces retain canonical First Last initials. Combining marks are cleaned without breaking ZWJ or skin-tone emoji (`AvatarIdentityTests`).
- New clients go through `ClientRepository` → `ClientCreationCoordinator`, an actor that serializes creation and inserts the `AppNotification` in the same save as the client.
- Behavior badges, auras and the aggressive banner follow `.claude/rules/pet-behavior.md`.

- Search uses multi-token AND word-prefix matching, case/diacritic/width folding, punctuation-tolerant names, NANP phone normalization, and `n:`, `f:`, `l:`, `p:`, `pet:`, `breed:`, `email:` scopes. Complete phone keys match exactly; partial digits stay searchable. Explicit email scope retains substring matching. Invalidate cached results through `ClientStoreRevision` immediately on save (`ClientSearchPrecisionTests`, `PhoneUtilsTests`).
