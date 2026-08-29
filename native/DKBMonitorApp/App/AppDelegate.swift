import AppKit

/// Minimal AppKit glue for the 3 behaviors SwiftUI Scenes don't expose
/// (see D2/Mục 2 in docs/swift-native-port-plan.md): keep running after the
/// last window closes, reopen on Dock click, and restore Regular activation
/// policy (Dock icon) when reopening.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarStatsViewModel.shared.start()
        NotificationManager.shared.onRouteSelected = { route in
            AppNavigationState.shared.handleNotificationRoute(route)
        }
        Task { await AppScheduler.shared?.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WindowPresenter.showMainWindow()
        return true
    }
}
