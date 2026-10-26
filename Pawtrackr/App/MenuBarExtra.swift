import Foundation

enum AppMenuCommand {
    static let pendingNewClientRequestKey = "pendingNewClientRequestID"
    static let pendingClientSearchFocusKey = "pendingClientSearchFocusID"
}

#if os(macOS)
import SwiftUI
import SwiftData

struct PawtrackrMenuBarExtra: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    // Bounded so the menu never freezes if abandoned active visits accumulate.
    // Only the first 5 are shown anyway; cap the fetch at 50 for the count badge.
    @Query(
        Self.activeVisitsDescriptor()
    ) private var activeVisits: [Visit]

    private static func activeVisitsDescriptor() -> FetchDescriptor<Visit> {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return descriptor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pawtrackr")
                    .font(.headline)
                Spacer()
                if activeVisits.count > 0 {
                    Text(String.localizedStringWithFormat(
                        AppLocalization.localized("menu_bar.active_count_fmt", value: "%d Active"),
                        activeVisits.count
                    ))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
            }
            .padding(.bottom, 4)

            Divider()

            if activeVisits.isEmpty {
                Text(AppLocalization.localized("menu_bar.no_active_visits", value: "No active visits"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(activeVisits.prefix(5)), id: \.uuid) { visit in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(visit.pet?.name ?? AppLocalization.localized("common.unknown_pet", value: "Unknown Pet"))
                                .font(.subheadline.weight(.medium))
                            Text(visit.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            Divider()

            Button(AppLocalization.localized("menu_bar.new_client", value: "New Client…")) {
                UserDefaults.standard.set(UUID().uuidString, forKey: AppMenuCommand.pendingNewClientRequestKey)
                openMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NotificationCenter.default.post(name: .showNewClientSheet, object: nil)
                }
            }

            Button(AppLocalization.localized("mac.command.show_insights", value: "Show Insights")) {
                openWindow(id: "insights-window")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button(AppLocalization.localized("menu_bar.open_main_window", value: "Open Main Window")) {
                openMainWindow()
            }

            Divider()

            Button(AppLocalization.localized("menu_bar.quit", value: "Quit Pawtrackr")) {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

extension Notification.Name {
    static let showNewClientSheet = Notification.Name("showNewClientSheet")
    static let focusClientSearch = Notification.Name("focusClientSearch")
}
