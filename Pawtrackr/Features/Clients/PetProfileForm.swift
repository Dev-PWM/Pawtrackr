import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The same compact profile fields for new clients, additional pets, and editing.
struct PetProfileForm: View {
    @Binding var name: String
    @Binding var species: Species
    @Binding var gender: PetGender
    @Binding var breed: String
    @Binding var color: String
    @Binding var photoData: Data?
    @Binding var birthdate: Date?
    var registrationDate: Date = .now
    var identifierPrefix = "petProfile"
    var focusName = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, breed, color }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                ImagePicker(imageData: $photoData) {
                    VStack(spacing: 8) {
                        AvatarView(.pet(species: species, gender: gender, name: name, imageData: photoData), size: .lg)
                        Text(AppLocalization.localized("add_pet.choose_photo", value: "Choose Photo"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .pressScaleStyle()
                .accessibilityLabel(AppLocalization.localized("add_pet.choose_photo", value: "Choose Photo"))
                Spacer()
            }
            PetProfileTextField(title: AppLocalization.localized("add_pet.name", value: "Name"), text: $name, limit: TextInputLimits.name)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .breed }
                .accessibilityIdentifier("\(identifierPrefix).name")
            Picker(AppLocalization.localized("add_pet.species", value: "Species"), selection: $species) {
                Text(Species.dog.displayName).tag(Species.dog)
                Text(Species.cat.displayName).tag(Species.cat)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppLocalization.localized("add_pet.species", value: "Species"))
            Picker(AppLocalization.localized("add_pet.gender", value: "Gender"), selection: $gender) {
                Text(PetGender.male.displayName).tag(PetGender.male)
                Text(PetGender.female.displayName).tag(PetGender.female)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppLocalization.localized("add_pet.gender", value: "Gender"))
            PetProfileTextField(title: AppLocalization.localized("add_pet.breed", value: "Breed (optional)"), text: $breed, limit: TextInputLimits.shortText)
                .focused($focusedField, equals: .breed)
                .submitLabel(.next)
                .onSubmit { focusedField = .color }
            PetProfileTextField(title: AppLocalization.localized("add_pet.color", value: "Color (optional)"), text: $color, limit: TextInputLimits.shortText)
                .focused($focusedField, equals: .color)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
            Divider()
            PetBirthdayFields(species: species, birthdate: $birthdate, registrationDate: registrationDate)
        }
        .onChange(of: focusName) { _, requested in
            if requested { focusedField = .name }
        }
        .padding(16)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
                .fill(DS.ColorToken.gender(gender)).frame(height: 4)
                .accessibilityHidden(true)
        }
    }
}

private struct PetProfileTextField: View {
    let title: String
    @Binding var text: String
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .textLengthLimit($text, to: limit)
                .padding(10)
                .background(DS.ColorToken.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()
        }
    }
}

/// Only the factual birthdate is editable. Age, stage, and the fallback anniversary are automatic.
struct PetBirthdayFields: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let species: Species

    private var isCompactPhone: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
    @Binding var birthdate: Date?
    let registrationDate: Date
    /// Fixed for the life of the form: rebuilding `...Date()` on every body
    /// pass handed the picker a new range each redraw, which reset it mid-edit.
    @State private var latestBirthdate = Date.now
    @State private var isShowingCalendar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum BirthdayOption: String, CaseIterable, Identifiable {
        case known
        case celebration
        var id: String { rawValue }
    }

    private var selectedOption: Binding<BirthdayOption> {
        Binding(
            get: { birthdate != nil ? .known : .celebration },
            set: { newOption in
                if newOption == .known {
                    // Today is only a placeholder, so go straight to the calendar.
                    if birthdate == nil { isShowingCalendar = true }
                    birthdate = birthdate ?? latestBirthdate
                } else {
                    birthdate = nil
                }
            }
        )
    }

    private var birthdateSelection: Binding<Date> {
        Binding(get: { birthdate ?? latestBirthdate }, set: { birthdate = $0 })
    }

    /// A date button that expands a graphical calendar in place, on every
    /// platform. The compact picker's popup broke inside the New Client sheet:
    /// tapping it scrolled the still-focused owner name field back into view,
    /// and the calendar opened detached from the field that had moved away.
    /// The Mac's compact style has no calendar at all, only a stepper field.
    @ViewBuilder
    private var birthdatePicker: some View {
        let title = AppLocalization.localized("pet.birthday.date", value: "Date")
        LabeledContent(title) {
            Button {
                Self.endTextEditing()
                withAnimation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion)) {
                    isShowingCalendar.toggle()
                }
            } label: {
                // Text(_:format:) follows the app's language; .formatted() would use the system's.
                Label {
                    Text(birthdateSelection.wrappedValue, format: .dateTime.day().month(.abbreviated).year())
                } icon: {
                    Image(systemName: "calendar")
                }
                .foregroundStyle(isShowingCalendar ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.ColorToken.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .pressScaleStyle()
            .accessibilityLabel(title)
            .accessibilityValue(Text(birthdateSelection.wrappedValue, format: .dateTime.day().month(.wide).year()))
            .accessibilityIdentifier("petProfile.birthdate")
        }
        if isShowingCalendar {
            DatePicker(title, selection: birthdateSelection, in: ...latestBirthdate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .transition(.opacity)
        }
    }

    /// Resigns the active text field so the form doesn't scroll back to it.
    private static func endTextEditing() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }

    private var birthdayModePicker: some View {
        Picker(AppLocalization.localized("pet.birthday.title", value: "Birthday"), selection: selectedOption) {
            Text(AppLocalization.localized("pet.birthday.known", value: "Known birthdate")).tag(BirthdayOption.known)
            Text(AppLocalization.localized("pet.birthday.celebration", value: "Salon anniversary"))
                .tag(BirthdayOption.celebration)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppLocalization.localized("pet.birthday.title", value: "Birthday"), systemImage: "birthday.cake.fill")
                .font(.subheadline.weight(.semibold))
            Group {
                if isCompactPhone {
                    birthdayModePicker.pickerStyle(.menu)
                } else {
                    birthdayModePicker.pickerStyle(.segmented)
                }
            }
            .accessibilityLabel(AppLocalization.localized("pet.birthday.title", value: "Birthday"))
            .accessibilityIdentifier("petProfile.birthdayMode")

            if birthdate != nil {
                birthdatePicker
            } else {
                LabeledContent(AppLocalization.localized("pet.birthday.registered", value: "Pet registered")) {
                    Text(registrationDate, format: .dateTime.month(.wide).day())
                }
                .font(.subheadline)
                Text(AppLocalization.localized(
                    "pet.birthday.celebration_help",
                    value: "When the birthdate is unknown, celebrate the client’s years with the salon, "
                        + "using their earliest registration or completed visit. This never sets the pet’s age."
                ))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let stage = PetLifeStage.estimate(birthdate: birthdate, species: species, on: context.date) {
                    Label(String(format: AppLocalization.localized("pet.stage.estimated", value: "%@ · estimated"), stage.title(for: species)), systemImage: stage == .senior ? "cross.case.fill" : "pawprint.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stage == .senior ? Color.orange : Color.secondary)
                    if stage == .senior {
                        Text(AppLocalization.localized("pet.stage.senior_care", value: "Senior · Check comfort and handling needs with the owner."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(AppLocalization.localized("pet.stage.about", value: "About life stages")) {
                Text(AppLocalization.localized("pet.stage.help", value: "Calculated automatically from the birthdate: puppy/kitten under 1, adult, senior at 8+ for dogs or 11+ for cats. This is a general guide; dogs vary by breed and size. Senior does not automatically mean special needs."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityLabel(AppLocalization.localized("pet.stage.about", value: "About life stages"))
        }
    }
}
