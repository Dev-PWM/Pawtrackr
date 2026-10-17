import Foundation
import SwiftData

private enum ClientSearchText {
    /// Treats punctuation as word boundaries and apostrophes as part of a name.
    static func words(_ folded: String) -> [String] {
        folded.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "ʼ", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Parses a query once, then applies strict AND matching within each owner's record.
struct ClientSearchQuery: Sendable {
    private enum Term: Sendable {
        case text(raw: String, words: [String])
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
        let hadInput = !text.isEmpty
        text = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        // Extensions aren't stored in the lookup key; ignore them only after a complete number.
        if scope == nil || scope == "p",
           let suffix = text.range(of: #"(?<=\d)\s*(?:ext(?:ension)?\.?|x|#)\s*\d+\s*$"#,
                                   options: .regularExpression),
           text[..<suffix.lowerBound].filter(\.isNumber).count >= 10 {
            text.removeSubrange(suffix)
        }
        let tokens = text.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "“", with: " ")
            .replacingOccurrences(of: "”", with: " ")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var parsed: [Term] = []
        var numberFragments: [String] = []
        for token in tokens {
            if scope != "email", token.allSatisfy({ $0.isNumber || "()+-./".contains($0) }) {
                numberFragments.append(token)
            } else {
                if !numberFragments.isEmpty {
                    parsed.append(.phone(digits: Self.phoneDigits(numberFragments),
                                         textFallback: numberFragments.flatMap(ClientSearchText.words)))
                    numberFragments = []
                }
                parsed.append(.text(raw: token, words: ClientSearchText.words(token)))
            }
        }
        if !numberFragments.isEmpty {
            parsed.append(.phone(digits: Self.phoneDigits(numberFragments),
                                 textFallback: numberFragments.flatMap(ClientSearchText.words)))
        }
        self.terms = parsed
        self.scope = scope
        self.isValid = valid && (!hadInput || !parsed.isEmpty)
    }

    /// Keeps a typed +1 prefix from hiding matches while the main number is incomplete.
    private static func phoneDigits(_ fragments: [String]) -> String {
        let input = fragments.joined()
        let digits = PhoneUtils.searchKey(input)
        if input.hasPrefix("+1"), input.filter(\.isNumber).count <= 10 {
            return String(digits.dropFirst())
        }
        return digits
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
        let words = searchableWords(in: record)
        let phone = record.phone
        return terms.allSatisfy { term in
            switch term {
            case .text(let raw, let tokens):
                return matchesText(raw, tokens: tokens, words: words, email: record.email)
            case .phone(let digits, let tokens):
                if scope == nil || scope == "p", !digits.isEmpty {
                    if digits.count >= 10 ? phone == digits : phone.contains(digits) { return true }
                    if digits.count >= 10 { return false }
                }
                return !tokens.isEmpty && tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
            }
        }
    }

    /// Preserves email substrings while allowing periods to separate ordinary name words.
    private func matchesText(_ raw: String, tokens: [String], words: [String], email: String) -> Bool {
        guard !tokens.isEmpty else { return false }
        if scope == "email" || (scope == nil && raw.contains("@")) {
            return email.contains(raw)
        }
        if scope == nil && raw.contains(".") && email.contains(raw) { return true }
        return tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
    }

    /// Restricts tokens to the requested field while retaining cross-field AND matching.
    private func searchableWords(in record: ClientSearchRecord) -> [String] {
        switch scope {
        case "f": record.firstNameWords
        case "l": record.lastNameWords
        case "n": record.firstNameWords + record.lastNameWords
        case "p", "email": []
        case "pet": record.petNameWords
        case "breed": record.petBreedWords
        default: record.allWords
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
    let firstNameWords: [String]
    let lastNameWords: [String]
    let petNameWords: [String]
    let petBreedWords: [String]
    let allWords: [String]
    let ordering: ClientListOrdering.Key
    let incomplete: Bool
    let attentionDueAt: Date?

    /// Normalizes searchable text exactly once when the store snapshot changes.
    init(_ client: Client) {
        id = client.persistentModelID
        let normalize: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }
        firstName = normalize(client.firstName)
        lastName = normalize(client.lastName)
        email = normalize(client.email ?? "")
        phone = client.searchKeysVersion == 1 ? client.phoneDigits : PhoneUtils.searchKey(client.phone ?? "")
        let pets = (client.pets ?? []).filter { $0.archivedAt == nil }
        petNames = pets.map { normalize($0.name) }
        petBreeds = pets.compactMap(\.breed).map(normalize)
        firstNameWords = ClientSearchText.words(firstName)
        lastNameWords = ClientSearchText.words(lastName)
        petNameWords = petNames.flatMap(ClientSearchText.words)
        petBreedWords = petBreeds.flatMap(ClientSearchText.words)
        allWords = firstNameWords + lastNameWords + ClientSearchText.words(email) + petNameWords + petBreedWords
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
