import Observation

/// Sidebar selection, shared between `ContentView` and whatever triggers
/// navigation from outside the view hierarchy — currently just
/// `NotificationManager`'s click-through route (`storeAndNotify`'s
/// `"/targets/\(id)"`/`"/servers/\(id)"` routes, wired in
/// `AppDelegate`).
@MainActor
@Observable
final class AppNavigationState {
    static let shared = AppNavigationState()

    var sidebarSelection: SidebarSection = .domains

    /// Set when a notification click should push `TargetDetailView` for a
    /// specific target — `OverviewView` observes this and clears it once
    /// consumed, since `NavigationPath` itself lives in that view's local
    /// state and isn't reachable from here.
    var pendingDetailTargetID: Int64?

    /// The same idea for the Server Manager's own `NavigationPath`, used by
    /// the remote resource alerts' `/servers/<id>` route.
    var pendingDetailServerID: Int64?

    /// The Network pages' detail pushes, for notification routes
    /// `/network/devices/<id>` and `/network/sources/<id>`.
    var pendingDeviceID: Int64?
    var pendingSourceID: Int64?

    /// A device page's "Monitor as a Domain" / "Add to Server Manager":
    /// the Add sheet of that page, filled in.
    struct Prefill: Equatable {
        let name: String
        let address: String
    }

    var pendingNewTarget: Prefill?
    var pendingNewServer: Prefill?

    /// Which Settings sub-page is open. Kept here rather than in the view so
    /// the page survives switching sidebar tabs and back.
    var settingsPath: [SettingsPage] = []

    private init() {}

    func handleNotificationRoute(_ route: String) {
        if route.hasPrefix("/targets/"), let id = Int64(route.dropFirst("/targets/".count)) {
            sidebarSelection = .domains
            OverviewViewModel.shared.selection = [id]
            pendingDetailTargetID = id
        } else if route.hasPrefix("/servers/"), let id = Int64(route.dropFirst("/servers/".count)) {
            sidebarSelection = .remoteServers
            pendingDetailServerID = id
        } else if route.hasPrefix("/network/devices/"), let id = Int64(route.dropFirst("/network/devices/".count)) {
            sidebarSelection = .networkDevices
            pendingDeviceID = id
        } else if route.hasPrefix("/network/sources/"), let id = Int64(route.dropFirst("/network/sources/".count)) {
            sidebarSelection = .networks
            pendingSourceID = id
        }
    }

    func openNewTarget(name: String, url: String) {
        pendingNewTarget = Prefill(name: name, address: url)
        sidebarSelection = .domains
    }

    func openNewServer(name: String, host: String) {
        pendingNewServer = Prefill(name: name, address: host)
        sidebarSelection = .remoteServers
    }
}
