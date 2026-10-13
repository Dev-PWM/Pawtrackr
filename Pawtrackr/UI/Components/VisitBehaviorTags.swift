import SwiftUI

/// Displays immutable visit observations, independent of the pet's current
/// safety clearance. An aggressive visit remains visibly red in history.
struct VisitBehaviorTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(Pet.cleanedBehaviorTags(tags), id: \.self) { tag in
                let kind = Pet.behaviorTagKind(for: tag)
                let display = BehaviorTagIcons.display(for: tag)
                let tint = BehaviorTagIcons.tint(for: kind)
                HStack(spacing: 5) {
                    if kind == .aggressive {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                    }
                    Text(display.label)
                        .foregroundStyle(.primary)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(tint, lineWidth: kind == .aggressive ? 2 : 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(display.label)
                .accessibilityIdentifier("visit.behavior.\(kind?.rawValue ?? tag)")
            }
        }
        .accessibilityLabel(Pet.cleanedBehaviorTags(tags).map { BehaviorTagIcons.display(for: $0).label }.joined(separator: ", "))
    }
}
