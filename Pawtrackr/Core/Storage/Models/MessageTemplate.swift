//
//  MessageTemplate.swift
//  Pawtrackr
//
//  Model for reusable communication templates.
//

import Foundation
import SwiftData

@Model
final class MessageTemplate {
    var title: String = ""
    var content: String = ""

    // Persist the enum's String rawValue, NOT the enum itself. Storing a Codable
    // enum directly makes SwiftData create a "composite attribute" that FATALLY
    // (e.g. after the case set changed — an older "Reminder" value broke macOS).
    // value falls back to `.custom` instead of crashing.
    var typeRaw: String = MessageTemplate.TemplateType.custom.rawValue

    /// Non-persisted view over `typeRaw`, preserving the existing `template.type`
    /// API. `@Transient` is REQUIRED: without it the `@Model` macro still persists
    /// this as a composite `type` attribute, which is exactly what crashes when an
    /// old record holds an unknown raw value (e.g. "Reminder").
    @Transient
    var type: TemplateType {
        get { TemplateType(rawValue: typeRaw) ?? .custom }
        set { typeRaw = newValue.rawValue }
    }

    enum TemplateType: String, Codable, CaseIterable, Identifiable {
        case readyForPickup = "Ready"
        case appointmentReminder = "Appointment Reminder"
        case runningLate = "Running Late"
        case followUp = "Follow-up"
        case custom = "Custom"

        var id: String { rawValue }
    }

    init(title: String, content: String, type: TemplateType = .custom) {
        self.title = title
        self.content = content
        self.typeRaw = type.rawValue
    }
    
    @MainActor
    func processedContent(pet: Pet?, visit: Visit?) -> String {
        var result = content
        if let pet = pet {
            result = result.replacingOccurrences(of: "[PetName]", with: pet.name)
        }
        if let owner = pet?.owner {
            result = result.replacingOccurrences(of: "[OwnerName]", with: owner.firstName)
        }
        if let visit = visit {
            result = result.replacingOccurrences(of: "[Time]", with: visit.startedAt.formatted(date: .omitted, time: .shortened))
            let total = visit.total > .zero ? visit.total : visit.effectiveTotal
            result = result.replacingOccurrences(of: "[Total]", with: total.moneyString)
        }
        return result
    }
    
    /// The localization key stem of each built-in template, in display order.
    static let builtInKeys: [(type: TemplateType, key: String)] = [
        (.readyForPickup, "ready"),
        (.appointmentReminder, "reminder"),
        (.runningLate, "running_late"),
        (.followUp, "follow_up")
    ]

    /// Every wording the app has shipped for a built-in template, one per
    /// bundled language (English, Spanish, Latin American Spanish).
    ///
    /// Seeded templates are stored in the language the app had when they were
    /// created, so recognizing a stored template means checking all of them.
    /// - Parameter type: A built-in template type; `.custom` has no wordings.
    /// - Returns: Distinct `(title, content)` pairs.
    static func shippedWordings(for type: TemplateType) -> [(title: String, content: String)] {
        guard let key = builtInKeys.first(where: { $0.type == type })?.key else { return [] }
        let titleKey = "message_template.\(key).title"
        let contentKey = "message_template.\(key).content"
        var wordings: [(title: String, content: String)] = []
        for lproj in ["en", "es", "es-419"] {
            guard let url = Bundle.main.url(forResource: lproj, withExtension: "lproj"),
                  let bundle = Bundle(url: url)
            else { continue }
            let title = bundle.localizedString(forKey: titleKey, value: nil, table: nil)
            let content = bundle.localizedString(forKey: contentKey, value: nil, table: nil)
            guard title != titleKey, content != contentKey,
                  !wordings.contains(where: { $0.title == title && $0.content == content })
            else { continue }
            wordings.append((title, content))
        }
        return wordings
    }

    static var defaults: [MessageTemplate] {
        [
            MessageTemplate(
                title: AppLocalization.localized("message_template.ready.title", value: "Ready for Pickup"),
                content: AppLocalization.localized("message_template.ready.content", value: "Hi [OwnerName], [PetName] is all finished and ready for pickup. See you soon!"),
                type: .readyForPickup
            ),
            MessageTemplate(
                title: AppLocalization.localized("message_template.reminder.title", value: "Appointment Reminder"),
                content: AppLocalization.localized("message_template.reminder.content", value: "Hi [OwnerName], this is a quick reminder for [PetName]'s Pawtrackr visit today. Reply if you need to adjust timing."),
                type: .appointmentReminder
            ),
            MessageTemplate(
                title: AppLocalization.localized("message_template.running_late.title", value: "Running Late"),
                content: AppLocalization.localized("message_template.running_late.content", value: "Hi [OwnerName], [PetName]'s visit is running a little longer than expected. We'll message you as soon as they're ready."),
                type: .runningLate
            ),
            MessageTemplate(
                title: AppLocalization.localized("message_template.follow_up.title", value: "Post-Visit Follow-up"),
                content: AppLocalization.localized("message_template.follow_up.content", value: "Hi [OwnerName], thanks for bringing [PetName] to Pawtrackr today! We hope they enjoyed their spa day."),
                type: .followUp
            )
        ]
    }
}
