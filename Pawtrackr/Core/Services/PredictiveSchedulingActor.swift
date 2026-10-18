//
//  PredictiveSchedulingActor.swift
//  Pawtrackr
//
//  Advanced background actor for predictive business intelligence.
//  Analyzes pet visit history to identify churn risk and suggest re-engagement.
//

import Foundation
import SwiftData
import OSLog

struct SmartSuggestion: Identifiable, Sendable {
    let id = UUID()
    let petID: PersistentIdentifier
    let clientID: PersistentIdentifier?
    let petName: String
    let ownerName: String
    let message: String
    let actionType: ActionType
    /// Days overdue divided by typical interval. Higher = more urgent.
    /// Used to sort suggestions so the groomer sees the most-overdue pets first.
    let overdueRatio: Double

    enum ActionType: Sendable {
        case call, text, rebook
    }
}

@ModelActor
final actor PredictiveSchedulingActor {
    
    func generateSuggestions() async throws -> [SmartSuggestion] {
        let context = modelContext
        
        // 1. Fetch all pets with their visit history
        var descriptor = FetchDescriptor<Pet>()
        descriptor.relationshipKeyPathsForPrefetching = [\.visits, \.owner]
        let pets = try context.fetch(descriptor)
        
        let now = Date.now
        var suggestions: [SmartSuggestion] = []

        for pet in pets {
            // Re-engage only once the pet is past its grooming cadence — the SAME
            // signal as `needsAttention`, so the dashboard's two sections stay in
            // sync. The cadence is species-based (dogs ~monthly, cats ~every 6
            // months) unless the owner set an explicit preference.
            guard pet.isOverdue,
                  let suggested = pet.suggestedNextVisitDate,
                  let interval = pet.suggestedGroomingInterval, interval > 0,
                  let lastVisitDate = (pet.visits ?? []).compactMap({ $0.endedAt }).max() else { continue }

            let daysOverdue = max(
                1,
                Calendar.current.dateComponents([.day], from: suggested, to: now).day ?? 1
            )
            let cadence = Self.cadenceLabel(forInterval: interval)

            let actionType: SmartSuggestion.ActionType
            if pet.owner?.smsURL != nil {
                actionType = .text
            } else if pet.owner?.telURL != nil {
                actionType = .call
            } else {
                actionType = .rebook
            }

            suggestions.append(SmartSuggestion(
                petID: pet.persistentModelID,
                clientID: pet.owner?.persistentModelID,
                petName: pet.name,
                ownerName: pet.owner?.fullName ?? "Unknown Owner",
                message: "\(pet.name) is \(daysOverdue)d past the recommended \(cadence) grooming cadence. Last visit \(lastVisitDate.formatted(date: .abbreviated, time: .omitted)).",
                actionType: actionType,
                overdueRatio: now.timeIntervalSince(lastVisitDate) / interval
            ))
        }

        // Most overdue first.
        return suggestions.sorted { $0.overdueRatio > $1.overdueRatio }
    }

    /// Human label for the cadence used in suggestion copy.
    private static func cadenceLabel(forInterval interval: TimeInterval) -> String {
        let days = Int((interval / (24 * 3600)).rounded())
        switch days {
        case ..<11: return "weekly"
        case 11..<21: return "every-2-weeks"
        case 21..<46: return "monthly"
        case 46..<135: return "quarterly"
        default: return "6-month"
        }
    }
}
