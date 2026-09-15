import Observation

/// Sidebar selection, shared between `ContentView` and whatever triggers
/// navigation from outside the view hierarchy — currently just
/// `NotificationManager`'s click-through route (`storeAndNotify`'s
/// `"/targets/\(id)"`/`"/servers/\(id)"`/`"/system"` routes, wired in
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

    private init() {}

    func handleNotificationRoute(_ route: String) {
        if route == "/system" {
            sidebarSelection = .system
        } else if route.hasPrefix("/targets/"), let id = Int64(route.dropFirst("/targets/".count)) {
            sidebarSelection = .domains
            OverviewViewModel.shared.selection = [id]
            pendingDetailTargetID = id
        } else if route.hasPrefix("/servers/"), let id = Int64(route.dropFirst("/servers/".count)) {
            sidebarSelection = .remoteServers
            pendingDetailServerID = id
        }
    }
}
