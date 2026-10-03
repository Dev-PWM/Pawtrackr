import Foundation
import SwiftData

/// Parses a query once, then applies strict AND matching within each owner's record.
struct ClientSearchQuery: Sendable {
    private enum Term: Sendable {
        case text(String)
        case phone(digits: String, textFallback: [String])
    }
    private let scope: String?
    private let terms: [Term]
    private let isValid: Bool

    /// Groups adjacent phone fragments so a formatted number must match contiguous digits.
    init(_ raw: String) {
        var text = raw.trimmed
        var scope: String?
        var valid = true
        if let colon = text.firstIndex(of: ":") {
            scope = String(text[..<colon]).lowercased()
            valid = ["n", "f", "l", "p", "pet", "breed", "email"].contains(scope!)
            text = String(text[text.index(after: colon)...]).trimmed
            valid = valid && !text.isEmpty
        }
        self.scope = scope
        self.isValid = valid
        let tokens = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var parsed: [Term] = []
        var numberFragments: [String] = []
        for token in tokens {
            if token.allSatisfy({ $0.isNumber || "()+-./".contains($0) }) {
                numberFragments.append(token)
            } else {
                if !numberFragments.isEmpty {
                    parsed.append(.phone(digits: PhoneUtils.searchKey(numberFragments.joined()), textFallback: numberFragments))
                    numberFragments = []
                }
                parsed.append(.text(token))
            }
        }
        if !numberFragments.isEmpty {
            parsed.append(.phone(digits: PhoneUtils.searchKey(numberFragments.joined()), textFallback: numberFragments))
        }
        self.terms = parsed
    }

    /// Matches only names, email, phone, and current pets; IDs never enter the search fields.
    func matches(_ client: Client) -> Bool {
        guard isValid else { return false }
        guard !terms.isEmpty else { return true }
        return matches(ClientSearchRecord(client))
    }

    /// Reuses pre-normalized fields while typing, without reading SwiftData model properties.
    func matches(_ record: ClientSearchRecord) -> Bool {
        guard isValid else { return false }
        guard !terms.isEmpty else { return true }
        let fields: [String]
        switch scope {
        case "f": fields = [record.firstName]
        case "l": fields = [record.lastName]
        case "n": fields = [record.firstName, record.lastName]
        case "p": fields = []
        case "pet": fields = record.petNames
        case "breed": fields = record.petBreeds
        case "email": fields = [record.email]
        default: fields = record.allFields
        }
        let phone = record.phone
        return terms.allSatisfy { term in
            switch term {
            case .text(let token):
                return fields.contains { $0.contains(token) }
            case .phone(let digits, let tokens):
                if (scope == nil || scope == "p"), !digits.isEmpty, phone.contains(digits) { return true }
                return tokens.allSatisfy { token in fields.contains { $0.contains(token) } }
            }
        }
    }
}

/// Immutable search data; the cache never retains SwiftData models or image data.
struct ClientSearchRecord: Sendable {
    let id: PersistentIdentifier
    let firstName: String
    let lastName: String
    let email: String
    let phone: String
    let petNames: [String]
    let petBreeds: [String]
    let allFields: [String]
    let ordering: ClientListOrdering.Key
    let incomplete: Bool
    let attentionDueAt: Date?

    /// Normalizes searchable text exactly once when the store snapshot changes.
    init(_ client: Client) {
        id = client.persistentModelID
        let normalize: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        firstName = normalize(client.firstName)
        lastName = normalize(client.lastName)
        email = normalize(client.email ?? "")
        phone = client.searchKeysVersion == 1 ? client.phoneDigits : PhoneUtils.searchKey(client.phone ?? "")
        let pets = (client.pets ?? []).filter { $0.archivedAt == nil }
        petNames = pets.map { normalize($0.name) }
        petBreeds = pets.compactMap(\.breed).map(normalize)
        allFields = [firstName, lastName, email] + petNames + petBreeds
        ordering = ClientListOrdering.Key(client)
        incomplete = ClientMissingInfo.isIncomplete(client)
        // Keep dates, not a cached Boolean: a due date can pass without a save.
        attentionDueAt = pets.compactMap { pet -> Date? in
            guard let due = pet.suggestedNextVisitDate else { return nil }
            if let outreach = pet.lastAttentionOutreachAt, outreach >= due { return nil }
            return due
        }.min()
    }
}

struct ClientSearchBook: Sendable {
    let records: [ClientSearchRecord]
    let activeIDs: Set<PersistentIdentifier>
}

/// Observes successful saves across local contexts, including direct writes and App Intents.
/// The lock protects this small revision counter on every writer's executor.
final class ClientStoreRevision: @unchecked Sendable {
    static let shared = ClientStoreRevision()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.generation &+= 1 }
        }
    }

    /// Reads the generation without crossing an actor or blocking database work.
    var current: UInt64 { lock.withLock { generation } }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// Creates each read context on a utility executor and propagates query cancellation.
enum ClientBackgroundQuery {
    /// Returns only Sendable values; no background-owned SwiftData object reaches the UI.
    static func run<Value: Sendable>(container: ModelContainer, operation: @escaping @Sendable (ModelContext) throws -> Value) async throws -> Value {
        try await values { try operation(ModelContext(container)) }
    }

    /// Filters cached values off the UI executor without creating unnecessary contexts.
    static func values<Value: Sendable>(operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}
