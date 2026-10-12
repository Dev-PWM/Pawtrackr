import SwiftUI
import SwiftData
import OSLog

/// Buffered pet editor shared by client profiles and pet detail.
struct EditPetSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let pet: Pet
    private let baseline: PetEditFields
    @State private var fields: PetEditFields
    @State private var isSaving = false
    @State private var error: AppError?
    @State private var confirmsRemoval = false

    init(pet: Pet) {
        self.pet = pet
        let snapshot = PetEditFields(pet: pet)
        baseline = snapshot
        _fields = State(initialValue: snapshot)

    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PetProfileForm(
                        name: $fields.name, species: $fields.species, gender: $fields.gender,
                        breed: $fields.breed, color: $fields.color, photoData: $fields.photoData,
                        birthdate: $fields.birthdate, registrationDate: pet.createdAt, identifierPrefix: "editPet"
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        if pet.archivedAt != nil {
                            Button(AppLocalization.localized("pet.editor.restore", value: "Restore Pet")) {
                                Task { await setRemoved(false) }
                            }
                            .pressScaleStyle()
                            .accessibilityLabel(AppLocalization.localized("pet.editor.restore", value: "Restore Pet"))
                        } else {
                            Button(AppLocalization.localized("pet.editor.remove", value: "Remove Pet"), role: .destructive) {
                                confirmsRemoval = true
                            }
                            .pressScaleStyle()
                            .accessibilityLabel(AppLocalization.localized("pet.editor.remove", value: "Remove Pet"))
                            .accessibilityIdentifier("editPet.remove")
                        }
                        Text(AppLocalization.localized("pet.editor.history_kept", value: "Removed pets leave current client lists. Their visit and payment history stays intact, and they can be restored."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .background(DS.ColorToken.background.ignoresSafeArea())
#if os(iOS)
            .scrollDismissesKeyboard(.interactively)
#endif
            .navigationTitle(AppLocalization.localized("pet.editor.title", value: "Edit Pet"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("common.cancel", value: "Cancel")) { dismiss() }
                        .pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("common.cancel", value: "Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("common.save", value: "Save")) { Task { await save() } }
                        .disabled(fields.name.trimmed.isEmpty)
                        .pressScaleStyle()
                        .accessibilityLabel(AppLocalization.localized("common.save", value: "Save"))
                        .accessibilityIdentifier("editPet.save")
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog(AppLocalization.localized("pet.editor.remove", value: "Remove Pet"), isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(AppLocalization.localized("pet.editor.remove", value: "Remove Pet"), role: .destructive) {
                    Task { await setRemoved(true) }
                }
            } message: {
                Text(AppLocalization.localized("pet.editor.history_kept", value: "Visit and payment history will be kept."))
            }
            .alert(item: $error) { error in
                Alert(title: Text(AppLocalization.localized("common.error", value: "Error")), message: Text(error.localizedDescription))
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 540, idealHeight: 650)
        #else
        .presentationDetents([.large])
        #endif
    }

    /// Saves profile changes through the model actor; hidden legacy care data stays intact.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await PetEditorRepository(modelContainer: modelContext.container)
                .save(id: pet.persistentModelID, fields: fields, baseline: baseline)
            NotificationCenter.default.post(name: .clientDidUpdate, object: nil)
            HapticManager.notify(.success)
            dismiss()
        } catch { report(error) }
    }

    /// Mirrors the actor's committed removal state without deleting historical relationships.
    private func setRemoved(_ removed: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await PetEditorRepository(modelContainer: modelContext.container)
                .setRemoved(id: pet.persistentModelID, removed: removed)
            NotificationCenter.default.post(name: .clientDidUpdate, object: nil)
            dismiss()
        } catch { report(error) }
    }

    /// Logs and surfaces failed persistence without dismissing the user's editor.
    private func report(_ failure: Error) {
        Logger.database.error("Pet editor failed: \(failure.localizedDescription, privacy: .public)")
        error = failure as? AppError ?? .database(failure.localizedDescription)
    }
}
