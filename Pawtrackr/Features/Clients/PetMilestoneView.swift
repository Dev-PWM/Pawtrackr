import SwiftUI

/// Read-only age and celebration cues, refreshed across local midnight without model writes.
struct PetMilestoneView: View {
    let pet: Pet

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let celebration = pet.celebrationStatus(on: context.date)
            let stage = pet.lifeStage(on: context.date)

            if celebration.isCelebrating || stage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let stage {
                        Label(String(format: AppLocalization.localized("pet.stage.estimated", value: "%@ · estimated"), stage.title(for: pet.species)), systemImage: stage == .senior ? "cross.case.fill" : "pawprint.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(stage == .senior ? Color.orange : Color.secondary)
                        if stage == .senior {
                            Text(AppLocalization.localized("pet.stage.senior_care", value: "Senior · Check comfort and handling needs with the owner."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if celebration.isCelebrating {
                        PetBirthdayBanner(name: pet.name, isHonorary: celebration.isHonorary)
                    }
                }
            }
        }
    }
}

/// A finite celebration that leaves readable text and respects Reduce Motion.
private struct PetBirthdayBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    let isHonorary: Bool
    @State private var appeared = false
    @State private var celebrationID = 0

    private var message: String {
        String(format: isHonorary
            ? AppLocalization.localized("pet.birthday.honorary_today", value: "It’s %@’s celebration day today!")
            : AppLocalization.localized("pet.birthday.today", value: "It’s %@’s birthday today!"), name)
    }

    var body: some View {
        Button {
            celebrationID += 1
        } label: {
            Label(message, systemImage: "birthday.cake.fill")
        }
            .pressScaleStyle()
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        ForEach(0..<16, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill([Color.orange, .pink, .mint, .yellow][index % 4])
                                .frame(width: 5, height: 9)
                                .rotationEffect(.degrees(appeared ? Double(index * 47) : 0))
                                .position(x: geometry.size.width * CGFloat(index + 1) / 17,
                                          y: appeared ? geometry.size.height + 10 : -10)
                                .opacity(appeared ? 0 : 1)
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: celebrationID) {
                appeared = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(MotionSystem.resolved(.easeOut(duration: 1.8), reduceMotion: reduceMotion)) { appeared = true }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .accessibilityIdentifier("petProfile.birthdayBanner")
    }
}
