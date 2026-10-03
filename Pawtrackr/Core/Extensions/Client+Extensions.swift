//
//  Client+Extensions.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-09-03.
//

import Foundation

// IMPROVEMENT: Centralize reusable business logic on the model itself.
extension Client {
    /// Display name that can follow the current client-list sort mode.
    func displayName(lastNameFirst: Bool = false) -> String {
        let first = firstName.trimmed
        let last = lastName.trimmed
        let parts = lastNameFirst ? [last, first] : [first, last]
        return parts
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A boolean indicating if any of the client's pets are currently checked in for a visit.
    var hasActiveVisit: Bool {
        (pets ?? []).contains { $0.isCheckedIn }
    }

    /// The start time of the most recent active visit, used for sorting "In Progress" clients.
    var sortKeyMostRecentVisit: Date {
        (pets ?? []).flatMap { $0.visits ?? [] }
            .map { $0.sortKeyDate }
            .max() ?? .distantPast
    }

    /// The most recent active visit object across all of this client's pets.
    var mostRecentActiveVisit: Visit? {
        (pets ?? []).flatMap { $0.visits ?? [] }
            .filter { $0.isActive }
            .max(by: { $0.startedAt < $1.startedAt })
    }

    /// The end time of the most recent completed visit across all pets.
    var mostRecentEndedAt: Date? {
        (pets ?? []).flatMap { $0.visits ?? [] }
            .compactMap { $0.endedAt }
            .max()
    }
}

// MARK: - Client search
extension Client {
    /// Requires every query token to match an owner field, phone segment, or
    /// current pet field. Phone punctuation and accents do not affect matches.
    func matches(searchQuery: String) -> Bool {
        ClientSearchQuery(searchQuery).matches(self)
    }
}
