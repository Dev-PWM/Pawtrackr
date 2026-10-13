import SwiftUI

enum NavigationItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case clients
    case insights
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard:
            return NSLocalizedString("dashboard.title", value: "Dashboard", comment: "")
        case .clients:
            return NSLocalizedString("clients.tab", value: "Clients", comment: "")
        case .insights:
            return NSLocalizedString("insights.tab", value: "Insights", comment: "")
        case .settings:
            return NSLocalizedString("settings.tab", value: "Settings", comment: "")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .clients: return "person.3.fill"
        case .insights: return "chart.bar.fill"
        case .settings: return "gear"
        }
    }

    /// The guided-tour spotlight target for this destination's sidebar row.
    var walkthroughAnchorID: WalkthroughAnchorID {
        switch self {
        case .dashboard: return .dashboard
        case .clients: return .clients
        case .insights: return .insights
        case .settings: return .settings
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    var onSelect: (NavigationItem) -> Void = { _ in }

    var body: some View {
        List {
            Section(NSLocalizedString("sidebar.section.business", value: "Business", comment: "")) {
                SidebarRow(item: .dashboard, selection: $selection, onSelect: onSelect)
                SidebarRow(item: .clients, selection: $selection, onSelect: onSelect)
            }

            Section(NSLocalizedString("sidebar.section.analysis", value: "Analysis", comment: "")) {
                SidebarRow(item: .insights, selection: $selection, onSelect: onSelect)
            }

            Section(NSLocalizedString("sidebar.section.system", value: "System", comment: "")) {
                SidebarRow(item: .settings, selection: $selection, onSelect: onSelect)
            }
        }
        .listStyle(.sidebar)
        // The Academy's first stop points at the whole menu.
        .walkthroughAnchor(.appNavigation)
        .glassmorphicSidebar()
        .tint(.primary)
        .navigationTitle("Pawtrackr")
    }
}

private struct SidebarRow: View {
    let item: NavigationItem
    @Binding var selection: NavigationItem?
    let onSelect: (NavigationItem) -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            selection = item
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).foregroundStyle(Color.primary)
                Text(item.label).foregroundStyle(Color.primary)
            }
                .font(.body.weight(selection == item ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressScaleStyle()
        .accessibilityLabel(item.label)
        .walkthroughAnchor(item.walkthroughAnchorID)
        .listRowBackground(rowBackground)
        .accessibilityIdentifier("sidebar.row.\(item.rawValue)")
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        #endif
    }

    private var rowBackground: Color {
        if selection == item {
            return Color.primary.opacity(0.10)
        }

        #if os(macOS)
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
        #else
        return Color.clear
        #endif
    }
}
