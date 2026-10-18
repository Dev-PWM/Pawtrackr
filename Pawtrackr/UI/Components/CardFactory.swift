
import SwiftUI

struct CardFactory {
    @ViewBuilder
    static func makeVisitTimelineRow(visit: Visit) -> some View {
        VisitTimelineRow(visit: visit)
    }
}
