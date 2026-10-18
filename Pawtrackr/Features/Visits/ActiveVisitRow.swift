
import SwiftUI

struct ActiveVisitRow: View {
    let visit: Visit
    @Environment(NavigationRouter.self) private var router
    @StateObject private var timer = VisitTimer()

    var body: some View {
        Card(elevation: .regular, accent: .leading(.color(DS.ColorToken.session), thickness: 4)) {
            HStack(spacing: 12) {
                AvatarView(.pet(species: visit.pet?.species, gender: visit.pet?.gender,
                                name: visit.pet?.name ?? "Unknown", imageData: visit.pet?.photoData), size: .md)
                VStack(alignment: .leading) {
                    Text(visit.pet?.name ?? "Unknown").font(.headline)
                    Text(visit.pet?.owner?.fullName ?? "").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()

                // Live-ticking timer
                Text(timer.formattedElapsed)
                    .font(.title2.weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(DS.ColorToken.primary)
                    .frame(minWidth: 92, alignment: .trailing)
                    .accessibilityLabel(timer.accessibilityElapsedLabel)

                if visit.pet != nil {
                    Button {
                        router.navigateToCheckout(visit)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalization.localized("a11y.session_options", value: "Session options"))
                    .accessibilityIdentifier("dashboard.activeSession.checkoutButton")
                }
            }
        }
        .onAppear {
            timer.load(startedAt: visit.startedAt, endedAt: visit.endedAt)
        }
    }
}
