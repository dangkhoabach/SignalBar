import SwiftUI
import DKBMonitorCore

/// Sidebar (Domains/System) + content. Settings lives in the native
/// `Settings {}` scene (Cmd+,) per Phase 12.
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
                SystemView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
