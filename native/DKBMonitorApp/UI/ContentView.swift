import SwiftUI

/// Sidebar (Domains/System/Settings) + content — Settings is a regular
/// sidebar tab so the app menu (Cmd+,) and the menu bar's "Settings…" both
/// land in the same place instead of a separate `Settings {}` window.
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
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
