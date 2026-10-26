//
//  CommunicationSheet.swift
//  Pawtrackr
//
//  Sheet to select a template and send a message to a client.
//

import SwiftUI
import SwiftData

struct CommunicationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query(sort: \MessageTemplate.title) private var templates: [MessageTemplate]
    
    let pet: Pet
    let visit: Visit?
    
    @State private var selectedTemplateTitle: String?
    @State private var customMessage: String = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section(AppLocalization.localized("communication.templates", value: "Templates")) {
                        ForEach(availableTemplates, id: \.title) { template in
                            templateButton(template)
                        }
                    }

                    Section(AppLocalization.localized("communication.message_preview", value: "Message Preview")) {
                        TextEditor(text: $customMessage)
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("communication.messagePreview")
                            .textLengthLimit($customMessage, to: TextInputLimits.notes)
                    }
                }

                sendActions
            }
            .navigationTitle(String(
                format: AppLocalization.localized("communication.title_fmt", value: "Message %@"),
                pet.owner?.firstName ?? AppLocalization.localized("communication.fallback_client", value: "Client")
            ))
            #if os(macOS)
            // A 420pt minimum overflowed a 390pt iPhone sheet.
            .frame(minWidth: 420, idealWidth: 520, maxWidth: 620, minHeight: 460, idealHeight: 560)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                }
            }
            .onAppear {
                DataMigrations.ensureMessageTemplates(in: modelContext)
                selectInitialTemplateIfNeeded()
            }
            .onChange(of: templates.count) {
                selectInitialTemplateIfNeeded()
            }
        }
        #if os(macOS)
        // macOS sheets size-to-fit and otherwise render cramped; give the
        // template picker a comfortable, iOS-like canvas.
        .frame(minWidth: 440, idealWidth: 460, minHeight: 560, idealHeight: 640)
        #endif
    }

    private var availableTemplates: [MessageTemplate] {
        // `ensureMessageTemplates` in onAppear can delete duplicate rows before
        // @Query refreshes, and reading a deleted row's fields can trap.
        let live = templates.filter { !$0.isDeleted && $0.modelContext != nil }
        let source = live.isEmpty ? MessageTemplate.defaults : live
        // One per built-in type, in case two contexts seeded at the same moment.
        var seenTypes = Set<MessageTemplate.TemplateType>()
        let unique = source.filter { $0.type == .custom || seenTypes.insert($0.type).inserted }
        return unique.sorted { lhs, rhs in
            let lhsRank = templateRank(lhs)
            let rhsRank = templateRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func templateRank(_ template: MessageTemplate) -> Int {
        switch template.type {
        case .readyForPickup: return 0
        case .appointmentReminder: return 1
        case .runningLate: return 2
        case .followUp: return 3
        case .custom: return 10
        }
    }

    @ViewBuilder
    private func templateButton(_ template: MessageTemplate) -> some View {
        let processed = template.processedContent(pet: pet, visit: visit)
        Button {
            selectedTemplateTitle = template.title
            customMessage = TextInputLimits.limited(processed, to: TextInputLimits.notes)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedTemplateTitle == template.title ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedTemplateTitle == template.title ? DS.ColorToken.primary : .secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title)
                        .font(.headline)
                    Text(processed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var sendActions: some View {
        HStack(spacing: 12) {
            Button(action: { sendMessage(method: .sms) }) {
                Label("SMS", systemImage: "message.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button(action: { sendMessage(method: .whatsapp) }) {
                Label("WhatsApp", systemImage: "bubble.left.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding()
        .disabled(customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func selectInitialTemplateIfNeeded() {
        guard customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = availableTemplates.first
        else { return }

        selectedTemplateTitle = first.title
        customMessage = TextInputLimits.limited(first.processedContent(pet: pet, visit: visit), to: TextInputLimits.notes)
    }
    
    enum MessageMethod {
        case sms, whatsapp
    }
    
    private func sendMessage(method: MessageMethod) {
        guard let phone = pet.owner?.phone else { return }
        
        let urlString: String?
        let boundedMessage = TextInputLimits.limited(customMessage, to: TextInputLimits.notes)
        switch method {
        case .sms:
            urlString = PhoneUtils.smsURLString(phone, body: boundedMessage)
        case .whatsapp:
            urlString = PhoneUtils.whatsappURLString(phone, body: boundedMessage)
        }
        
        guard let urlString = urlString, let url = URL(string: urlString) else { return }
        
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
        dismiss()
    }
}
