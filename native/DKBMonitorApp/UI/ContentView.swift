import SwiftUI
import DKBMonitorCore

/// Sidebar (Domains/System/Settings) + content. Domains is the Phase 11
/// Overview; System/Settings stay placeholders until Phase 12.
struct ContentView: View {
    @Bindable private var navigationState = AppNavigationState.shared

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: Binding(
                get: { navigationState.sidebarSelection },
                set: { if let newValue = $0 { navigationState.sidebarSelection = newValue } }
            )) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch navigationState.sidebarSelection {
            case .domains:
                OverviewView()
            case .system:
                Text("System — Phase 12")
                    .foregroundStyle(.secondary)
            case .settings:
                Text("Settings — Phase 12")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
