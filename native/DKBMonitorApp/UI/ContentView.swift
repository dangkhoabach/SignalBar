import SwiftUI
import DKBMonitorCore

/// Sidebar (Domains/System) + content. Settings lives in the native
/// `Settings {}` scene (Cmd+,) per Phase 12.
struct ContentView: View {
    @Bindable private var navigationState = AppNavigationState.shared
    @Bindable private var overviewViewModel = OverviewViewModel.shared

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
        // Attached to the NavigationSplitView itself, not to a view nested
        // inside its detail column — on macOS, `.searchable` on a
        // NavigationStack nested inside a split view's detail simply never
        // renders a search field (a known SwiftUI limitation). Only the
        // Domains section reads `searchText`; showing the field while on
        // System is a harmless no-op, same tradeoff Mail.app-style sidebar
        // apps make.
        .searchable(text: $overviewViewModel.searchText, prompt: Text("Search domains"))
    }
}
