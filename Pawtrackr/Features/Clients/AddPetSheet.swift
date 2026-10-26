//
//  AddPetSheet.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//

import SwiftUI
import SwiftData
import OSLog
// Design tokens for colors/spacing/typography
import Observation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct AddPetSheet: View {
    // Parent context & dismissal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    // Target owner
    @Bindable var client: Client

    // Form state
    @State private var petName: String = ""
    @State private var selectedSpecies: Species? = .dog
    @State private var selectedGender: PetGender = .male
    @State private var breed: String = ""
    @State private var color: String = ""
    @State private var birthdate: Date?

    // Image picking - Corrected to use Data?
    @State private var avatarImageData: Data? = nil

    // Alerts
    @State private var appError: AppError? = nil
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                PetProfileForm(
                    name: $petName, species: Binding($selectedSpecies, replacingNilWith: .dog),
                    gender: $selectedGender, breed: $breed, color: $color, photoData: $avatarImageData,
                    birthdate: $birthdate, identifierPrefix: "addPet"
                )
                .padding()
            }
            .background(DS.ColorToken.background.ignoresSafeArea())
#if os(iOS)
            // Drop focus on scroll, or the birthday menu scrolls back to the focused field.
            .scrollDismissesKeyboard(.immediately)
#endif
            .navigationTitle(NSLocalizedString("add_pet.title", comment: ""))
#if os(iOS)
            .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .inline : .automatic)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        #if os(iOS)
                        if horizontalSizeClass == .compact {
                            Image(systemName: "xmark")
                        } else {
                            Text(NSLocalizedString("common.cancel", comment: ""))
                        }
                        #else
                        Text(NSLocalizedString("common.cancel", comment: ""))
                        #endif
                    }
                        .accessibilityIdentifier("addPet.cancel")
                        .pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("common.cancel", value: "Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "")) { Task { await savePet() } }
                        .disabled(isSaving || petName.trimmed.isEmpty || selectedSpecies == nil)
                        .accessibilityHint(petName.trimmed.isEmpty ? "Enter a pet name to enable save" : "Saves this pet to the client")
                        .accessibilityIdentifier("addPet.save")
                        .pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("common.save", value: "Save"))
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .alert(item: $appError) { error in
                Alert(
                    title: Text(NSLocalizedString("add_pet.unable_to_save", comment: "")),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "")))
                )
            }
        }
#if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 540, idealHeight: 680)
#else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
#endif
        .accessibilityElement(children: .contain)
    }

    private func savePet() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard let species = selectedSpecies else {
            appError = .validation(.custom(message: NSLocalizedString("add_pet.select_species", comment: "")))
            return
        }
        let trimmedName = TextInputLimits.clamped(canonicalPetName(petName), to: TextInputLimits.name)
        guard !trimmedName.isEmpty else {
            appError = .validation(.custom(message: NSLocalizedString("add_pet.name_empty", comment: "")))
            return
        }

        let data = NewPetData(
            name: trimmedName, species: species, gender: selectedGender,
            breed: canonicalOptionalWord(breed).map { TextInputLimits.limited($0, to: TextInputLimits.shortText) },
            color: canonicalOptionalWord(color).map { TextInputLimits.limited($0, to: TextInputLimits.shortText) },
            photoData: avatarImageData,
            health: nil, behaviorTags: [], birthdate: birthdate
        )
        do {
            let repository = PetEditorRepository(modelContainer: modelContext.container)
            _ = try await repository.add(ownerID: client.persistentModelID, data: data)
            NotificationCenter.default.post(name: .clientDidUpdate, object: nil)
            HapticManager.notify(.success)
            dismiss()
        } catch {
            Logger.database.error("Pet creation failed: \(error.localizedDescription, privacy: .public)")
            appError = .database(error.localizedDescription)
        }
    }
}

// MARK: - Normalization

/// Title-cases common pet name patterns and trims whitespace.
private func canonicalPetName(_ raw: String) -> String {
    let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !base.isEmpty else { return "" }
    // Handle simple possessives / prefixes as needed later.
    return base.split(separator: " ").map { part in
        part.split(separator: "-").map { seg in
            var s = String(seg)
            if s.count >= 2 {
                let first = s.removeFirst()
                return String(first).uppercased() + s
            }
            return s.uppercased()
        }.joined(separator: "-")
    }.joined(separator: " ")
}

/// Returns a capitalized word/string or nil if the trimmed input is empty.
private func canonicalOptionalWord(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    return t.split(separator: " ").map { String($0).capitalized }.joined(separator: " ")
}

extension Binding {
    init(_ source: Binding<Value?>, replacingNilWith defaultValue: Value) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { newValue in source.wrappedValue = newValue }
        )
    }
}

#Preview {
    // Lightweight preview with an in-memory model
    let schema = Schema([Client.self, Pet.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    if let container = try? ModelContainer(for: schema, configurations: config) {
        let c = Client(firstName: "Sarah", lastName: "Johnson", phone: "(555) 123-4567")
        container.mainContext.insert(c)
        return AddPetSheet(client: c)
            .modelContainer(container)
    } else {
        return Text("Preview Unavailable")
    }
}
