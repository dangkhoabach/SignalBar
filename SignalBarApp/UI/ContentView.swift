import SwiftUI

/// Sidebar (Domains/Server Manager, the Network pages, Settings) + content — Settings is a regular
/// sidebar tab so the app menu (Cmd+,) and the menu bar's "Settings…" both
/// land in the same place instead of a separate `Settings {}` window.
///
/// Sidebar styling ported from MediaCatch's `ContentView`
/// (`native/MediaCatchApp/UI/ContentView.swift`): unselected row icons
/// dimmed to `.secondary` so the selected one reads as "lit up" against
/// them, a resizable min/ideal column width instead of a fixed one, and an
/// explicit `@FocusState` that's reclaimed after every tab switch — without
/// it, switching tabs drops first-responder off the sidebar `List` and its
/// selection pill renders in the gray "inactive window" style instead of
/// accent blue, even though the window itself is still key.
struct ContentView: View {
    @Bindable private var navigationState = AppNavigationState.shared
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { navigationState.sidebarSelection },
                set: { if let newValue = $0 { navigationState.sidebarSelection = newValue } }
            )) {
                Section {
                    ForEach([SidebarSection.domains, .remoteServers]) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(section == navigationState.sidebarSelection ? Color.primary : Color.secondary)
                        }
                        .tag(section)
                    }
                } header: {
                    Text("Monitoring")
                }
                Section {
                    ForEach([SidebarSection.connection, .networkDevices, .networkAddresses, .networks]) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                                .foregroundStyle(section == navigationState.sidebarSelection ? Color.primary : Color.secondary)
                        }
                        .tag(section)
                    }
                } header: {
                    Text("Network")
                }
            }
            // Settings is pinned under the list, as in the author's other apps.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSettingsRow(isSelected: navigationState.sidebarSelection == .settings) {
                    navigationState.sidebarSelection = .settings
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .focused($sidebarFocused)
        } detail: {
            switch navigationState.sidebarSelection {
            case .domains:
                OverviewView()
            case .remoteServers:
                RemoteServerListView()
            case .connection:
                ConnectionView()
            case .networkDevices:
                NetworkDevicesView()
            case .networkAddresses:
                NetworkAddressesView()
            case .networks:
                NetworksView()
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { sidebarFocused = true }
        .onChange(of: navigationState.sidebarSelection) { _, _ in sidebarFocused = true }
    }
}
