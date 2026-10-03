import Foundation

enum ClientListOrdering {
    /// Sorts by the selected primary key, then owner name and stable UUID.
    /// Empty primary keys sort after named records without sentinel strings.
    @MainActor static func sorted(_ clients: [Client], by option: ClientsViewModel.SortOption) -> [Client] {
        clients.map { (client: $0, key: Key($0)) }
            .sorted { precedes($0.key, $1.key, by: option) }.map(\.client)
    }

    /// Sendable ordering values shared by UI callers and background list queries.
    struct Key: Sendable {
        let first: String
        let last: String
        let pet: String
        let visit: Date
        let created: Date
        let uuid: UUID

        /// Reads model properties once on the context's owning executor.
        init(_ client: Client) {
            first = client.firstName.trimmed
            last = client.lastName.trimmed
            pet = (client.pets ?? []).filter { $0.archivedAt == nil }.map { $0.name.trimmed }
                .filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first ?? ""
            visit = client.lastVisitDate ?? .distantPast
            created = client.createdAt
            uuid = client.uuid
        }
    }

    /// Compares immutable keys without accessing SwiftData during sorting.
    static func precedes(_ lhs: Key, _ rhs: Key, by option: ClientsViewModel.SortOption) -> Bool {
        switch option {
        case .lastName:
            if let result = ascending(lhs.last, rhs.last) { return result }
            if let result = ascending(lhs.first, rhs.first) { return result }
        case .firstName:
            if let result = ascending(lhs.first, rhs.first) { return result }
            if let result = ascending(lhs.last, rhs.last) { return result }
        case .petName:
            if let result = ascending(lhs.pet, rhs.pet) { return result }
        case .lastVisit:
            if lhs.visit != rhs.visit { return lhs.visit > rhs.visit }
        case .newest:
            if lhs.created != rhs.created { return lhs.created > rhs.created }
        }
        if let result = ascending(lhs.last, rhs.last) { return result }
        if let result = ascending(lhs.first, rhs.first) { return result }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    /// Returns nil for equal keys so callers can evaluate a stable secondary key.
    private static func ascending(_ a: String, _ b: String) -> Bool? {
        let left = a
        let right = b
        if left.isEmpty != right.isEmpty { return !left.isEmpty }
        let comparison = left.localizedStandardCompare(right)
        return comparison == .orderedSame ? nil : comparison == .orderedAscending
    }
}
