import Observation

/// Sidebar selection, shared between `ContentView` and whatever triggers
/// navigation from outside the view hierarchy — currently just
/// `NotificationManager`'s click-through route (`storeAndNotify`'s
/// `"/targets/\(id)"`/`"/system"` routes, wired in `AppDelegate`).
@MainActor
@Observable
final class AppNavigationState {
    static let shared = AppNavigationState()

    var sidebarSelection: SidebarSection = .domains

    private init() {}

    func handleNotificationRoute(_ route: String) {
        if route == "/system" {
            sidebarSelection = .system
        } else if route.hasPrefix("/targets/"), let id = Int64(route.dropFirst("/targets/".count)) {
            sidebarSelection = .domains
            OverviewViewModel.shared.selection = [id]
        }
    }
}
