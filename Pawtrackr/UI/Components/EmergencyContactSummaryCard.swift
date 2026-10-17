//
//  EmergencyContactSummaryCard.swift
//  Pawtrackr
//

import SwiftUI

struct EmergencyContactSummaryCard: View {
    let contacts: [EmergencyContact]
    let ownerPhone: String?
    let ownerEmail: String?
    let onAdd: () -> Void
    let onEdit: (EmergencyContact) -> Void
    let onDelete: (EmergencyContact) -> Void

    /// The same rule as the client list's Missing Info filter.
    private var missingItems: [ClientMissingInfo] {
        ClientMissingInfo.items(hasEmergencyContact: !contacts.isEmpty, phone: ownerPhone, email: ownerEmail)
    }

    private var missingSummary: String {
        ClientMissingInfo.summary(missingItems) ?? ""
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text(AppLocalization.localized("client_detail.emergency_contacts", value: "Emergency Contacts"))
                    } icon: {
                        Image(systemName: "cross.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(DS.ColorToken.danger, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    .font(.headline)
                    Spacer()
                    Button(action: onAdd) {
                        Label(
                            AppLocalization.localized("client_detail.add_contact", value: "Add Contact"),
                            systemImage: "plus.circle.fill"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.ColorToken.danger)
                    .accessibilityLabel(AppLocalization.localized("client_detail.add_emergency_contact", value: "Add emergency contact"))
                    // The guided tour's "Add a Backup Contact" stop.
                    .walkthroughTarget(.emergencyContactBadges)
                }

                if !missingItems.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.ColorToken.warning)
                        Text(missingSummary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.ColorToken.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityElement(children: .combine)
                }

                if contacts.isEmpty {
                    Text(AppLocalization.localized(
                        "client_detail.emergency_empty_hint",
                        value: "Add a backup person staff can call if the owner is unreachable."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(contacts, id: \.uuid) { contact in
                            emergencyContactRow(contact)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("clientDetail.emergencyContacts")
    }

    private func emergencyContactRow(_ contact: EmergencyContact) -> some View {
        let telURL = PhoneUtils.telURLString(contact.phone).flatMap { URL(string: $0) }
        let smsURL = PhoneUtils.smsURLString(contact.phone).flatMap { URL(string: $0) }
        let displayPhone = EmergencyContactRules.displayPhone(contact.phone)

        return HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: telURL == nil ? "person.crop.circle.fill" : "phone.circle.fill")
                    .font(.title3)
                    .foregroundStyle(telURL == nil ? Color.secondary : DS.ColorToken.success)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(contactSubtitle(contact, displayPhone: displayPhone))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                if let telURL {
                    Button {
                        URLOpener.open(telURL)
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    .foregroundStyle(DS.ColorToken.success)
                    .accessibilityLabel(localized("client_detail.call_contact_fmt", value: "Call %@", contact.name))
                }

                Menu {
                    if let smsURL {
                        Button {
                            URLOpener.open(smsURL)
                        } label: {
                            Label(localized("client_detail.message_contact_fmt", value: "Message %@", contact.name), systemImage: "message")
                        }
                    }
                    if !displayPhone.isEmpty {
                        Button {
                            PasteboardWriter.copy(displayPhone)
                        } label: {
                            Label(AppLocalization.localized("client_detail.copy_phone", value: "Copy Phone"), systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        onEdit(contact)
                    } label: {
                        Label(localized("client_detail.edit_contact_fmt", value: "Edit %@", contact.name), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(contact)
                    } label: {
                        Label(localized("client_detail.delete_contact_fmt", value: "Delete %@", contact.name), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
                .accessibilityLabel(localized("client_detail.contact_actions_fmt", value: "Actions for %@", contact.name))
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button {
                onEdit(contact)
            } label: {
                Label(localized("client_detail.edit_contact_fmt", value: "Edit %@", contact.name), systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete(contact)
            } label: {
                Label(localized("client_detail.delete_contact_fmt", value: "Delete %@", contact.name), systemImage: "trash")
            }
        }
    }

    private func contactSubtitle(_ contact: EmergencyContact, displayPhone: String) -> String {
        let phone = displayPhone.isEmpty
            ? AppLocalization.localized("client_detail.contact_no_phone", value: "No phone number")
            : displayPhone
        if let relation = contact.relation?.trimmingCharacters(in: .whitespacesAndNewlines), !relation.isEmpty {
            return "\(relation) • \(phone)"
        }
        return phone
    }

    private func localized(_ key: String, value: String, _ argument: String) -> String {
        String(format: AppLocalization.localized(key, value: value), argument)
    }
}
